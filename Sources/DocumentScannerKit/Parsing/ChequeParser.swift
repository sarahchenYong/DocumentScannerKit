//
//  ChequeParser.swift
//  DocumentScannerKit
//
//  Extracts the fields a bank cheque carries — payee, bank, account number,
//  cheque number, IBAN, the amount in words and in figures, and the date —
//  from OCR lines. Cheques have no check digits, so this is heuristic: it
//  anchors on printed phrasing ("Pay", "or order", "Dirhams", "Only"), the
//  MICR band at the foot, a UAE bank-name list, and the shapes of amounts and
//  IBANs. The MICR (E-13B) font is read only approximately by Vision, so the
//  foot line is parsed by its digit groups rather than its transit symbols.
//

import Foundation

public struct ChequeResult: Codable, Equatable, Sendable {
    public var payee: String?
    public var accountHolder: String?
    public var bank: String?
    public var branch: String?
    public var accountNumber: String?
    public var chequeNumber: String?
    public var iban: String?
    public var amountInWords: String?
    public var amountInFigures: String?
    public var amountValue: Decimal?
    public var currency: String?
    public var date: String?
    public var micr: String?

    /// Normalized fields for the unified result, skipping empties. Each field
    /// carries a confidence reflecting how it was extracted: exact matches
    /// against known structure (bank list, IBAN shape) score high, printed
    /// labelled numbers high, positional heuristics medium, handwriting and
    /// the raw OCR of the MICR band low. (When the image pipeline decodes the
    /// band glyph-by-glyph it replaces the MICR fields with its measured
    /// match confidence.)
    public func scannedFields() -> [ScannedField] {
        var out: [ScannedField] = []
        func add(_ key: ScannedFieldKey, _ label: String, _ value: String?, _ confidence: Double) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            out.append(ScannedField(key: key, label: label, value: v,
                                    category: .banking, confidence: confidence))
        }
        add(.payeeName, "Payee Name", payee, 0.6)                // handwritten
        add(.accountHolder, "Account Holder", accountHolder, 0.85)
        add(.bankName, "Bank", bank, 0.95)                       // known-bank list match
        add(.branchName, "Branch", branch, 0.75)
        add(.accountNumber, "Account Number", accountNumber, 0.9)
        add(.chequeNumber, "Cheque Number", chequeNumber, 0.7)   // positional heuristic
        add(.iban, "IBAN", iban, 0.95)                           // strict format match
        // Regenerated from the validated figure (exact wording); OCR of the
        // handwritten line is much weaker.
        add(.amountInWords, "Amount (words)", amountInWords, amountValue != nil ? 0.85 : 0.5)
        add(.amountInFigures, "Amount (figures)", amountInFigures, 0.85)
        if let v = amountValue { add(.amountValue, "Amount (value)", "\(v)", 0.85) }
        add(.currency, "Currency", currency, 0.9)
        add(.chequeDate, "Date", date, 0.85)
        add(.micrLine, "MICR", micr, 0.4)                        // raw OCR of E-13B
        return out
    }

    public var hasContent: Bool { !scannedFields().isEmpty }
}

public enum ChequeParser {

    private static let amountRegex = try! NSRegularExpression(
        pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+\.\d{2}"#)

    /// A line dominated by digits and spaces, near the foot — the MICR band.
    public static func micrLine(in lines: [String]) -> String? {
        let indexed = Array(lines.enumerated())
        let candidates = indexed.suffix(max(3, lines.count / 2))
        for (_, raw) in candidates.reversed() where looksLikeMICR(raw) {
            return TextNormalization.normalizeDigits(raw).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// True for a line that reads like the E-13B band: digit-dominated, nearly
    /// letter-free, with any remaining characters drawn from the junk marks
    /// Vision substitutes for the MICR symbols (⑆ ⑈ etc. come out as „ # ° º
    /// | l I …). Bar-like letters are counted as symbol misreads, not letters.
    static func looksLikeMICR(_ raw: String) -> Bool {
        let s = TextNormalization.normalizeDigits(raw)
        let digits = s.filter { $0.isNumber }.count
        let letters = s.filter { $0.isLetter && !"lIiJj".contains($0) }.count
        let micrish = s.filter { "⑆⑈⑇⑉:|<>„“”‚''\"`´#°º•·*^~!lIiJj".contains($0) }.count
        return digits >= 12 && letters <= 3
            && (digits + micrish) >= s.filter({ !$0.isWhitespace }).count - 2
    }

    public static func parse(_ lines: [String]) -> ChequeResult? {
        guard !lines.isEmpty else { return nil }
        var r = ChequeResult()
        let lowerLines = lines.map { $0.lowercased() }

        r.bank = DocumentClassifier.matchedBankName(in: lines.joined(separator: " "))
        r.branch = branch(from: lines)
        r.payee = payee(from: lines, lowerLines: lowerLines)
        r.accountHolder = accountHolder(from: lines, branch: r.branch)
        // Any country's IBAN, length- and checksum-validated (with OCR
        // letter-for-digit repairs); the UAE-only regex remains the fallback
        // for a misread the checksum can't prove.
        r.iban = IBANExtractor.extract(from: lines)?.value
            ?? TextNormalization.firstMatch(DocumentClassifier.uaeIBANRegex, in: lines.joined(separator: " "))?
            .replacingOccurrences(of: " ", with: "")
        r.date = chequeDate(from: lines, lowerLines: lowerLines)

        r.accountNumber = labelledNumber(["account number", "account no", "a/c no", "ac no", "a/c"],
                                         in: lines, lowerLines: lowerLines, digits: 8...18, includePrevious: true)
            ?? ibanTailAccount(r.iban)

        // Cheque number: a 4–8 digit token, scored by cheque-label proximity,
        // zero-padding and position — robust to OCR variation and never sourced
        // from the MICR band (whose transit symbols misread as digits), so
        // MICR-looking lines are dropped from the search entirely.
        r.chequeNumber = chequeNumber(from: lines.filter { !looksLikeMICR($0) },
                                      excluding: Set([r.accountNumber].compactMap { $0 }))

        // MICR is the band along the foot. Mine it for missing numbers only
        // when it came through as pure digits/spaces — anything else means the
        // E-13B symbols were misread and no group boundary can be trusted; then
        // only the digit groups are surfaced, not the junk marks. (The image
        // pipeline replaces this with a symbol-exact decode when `MICRReader`
        // succeeds.)
        if let micr = micrLine(in: lines) {
            if micrIsCleanDigits(micr) {
                r.micr = micr
                let m = parseMICR(micr)
                if r.accountNumber == nil { r.accountNumber = m.account }
                if r.chequeNumber == nil { r.chequeNumber = m.cheque }
            } else {
                r.micr = micr.split(whereSeparator: { !$0.isNumber }).joined(separator: " ")
            }
        }
        if let acc = r.accountNumber, acc == r.chequeNumber { r.accountNumber = nil }

        // Amount in figures last, so we can exclude the cheque/account numbers.
        let exclude = Set([r.chequeNumber, r.accountNumber].compactMap { $0 })
        r.amountInFigures = amountInFigures(from: lines, excluding: exclude)
        if let figures = r.amountInFigures {
            r.amountValue = Decimal(string: figures.replacingOccurrences(of: ",", with: ""))
        }
        // Currency: a UAE cheque (AE IBAN) or any AED/Dirham cue ⇒ AED. Matching
        // "rham" tolerates OCR mangling like "Dırhams"/"Dishams".
        let aedCue = lowerLines.contains { $0.contains("aed") || $0.contains("rham")
            || $0.contains("dhs") || $0.contains("fils") }
        if r.iban?.hasPrefix("AE") == true || aedCue { r.currency = "AED" }

        // Amount in words: the handwritten line OCRs too poorly to trust, so we
        // regenerate it from the validated figure (exact). Fall back to the OCR
        // text only when there's no numeric amount.
        if let value = r.amountValue {
            r.amountInWords = AmountWords.string(from: value, currency: r.currency)
        } else {
            r.amountInWords = amountInWords(from: lines, lowerLines: lowerLines)
        }

        return r.hasContent ? r : nil
    }

    // MARK: - Field helpers

    private static let payeeStops = ["or order", "or bearer", "to the order of",
                                     "bearer", "dirhams", "dirham", "aed", "only"]

    /// Boilerplate / non-name words. A candidate containing any of these is the
    /// printed cheque wording ("Pay against this cheque to … or bearer"), a
    /// section label, or bank text — never the payee.
    private static let nonNameWords = [
        "against", "this cheque", "cheque", "bearer", "order", "dirham", "only",
        "balance", "previous", "deposit", "signature", "please", "date", "amount",
        "account", "a/c", "iban", "bank", "emirates", "central", "licensed", "number",
    ]

    /// Amount-in-words cue fragments (incl. common OCR manglings) used to reject
    /// the amount line from being mistaken for the payee.
    private static let amountWordCues = [
        "only", "odly", "ony", "thous", "thousan", "tharc", "tharç", "hund",
        "dirh", "disb", "fils", "balance", "biame", "previous", "deposit",
    ]
    private static func looksLikeAmountWords(_ s: String) -> Bool {
        let l = s.lowercased()
        return amountWordCues.contains { l.contains($0) }
    }

    /// The payee is the name written near the "Pay … or bearer" instruction.
    /// OCR reading order is unreliable — the handwritten name can land above or
    /// below the printed label — so we score every line in a window around each
    /// "Pay"/"or bearer"/"or order" anchor, preferring name-like lines close to
    /// the anchor and rejecting the amount-in-words line.
    private static func payee(from lines: [String], lowerLines: [String]) -> String? {
        var anchors = Set<Int>()
        for (i, lower) in lowerLines.enumerated() {
            if let r = lower.range(of: "pay") {
                let after = lower[r.upperBound...]
                if !after.hasPrefix("ee"), !after.hasPrefix("able") { anchors.insert(i) }
            }
            if lower.contains("bearer") || lower.contains("order") { anchors.insert(i) }
        }
        guard !anchors.isEmpty else { return nil }

        var best: (name: String, idx: Int, score: Int)?
        func consider(_ raw: String, at idx: Int, distance: Int) {
            guard let name = plausibleName(raw), !looksLikeAmountWords(raw) else { return }
            // Prefer names close to the anchor and MORE complete (more words), so
            // a fuller reading ("Saad Suhail Salim …") beats a truncated one.
            let score = (4 - min(distance, 3)) + min(name.split(separator: " ").count, 8)
            if best == nil || score > best!.score { best = (name, idx, score) }
        }
        for anchor in anchors {
            if let r = lowerLines[anchor].range(of: "pay") {
                consider(cut(String(lines[anchor][r.upperBound...]), atAnyOf: payeeStops), at: anchor, distance: 0)
            }
            for off in [-3, -2, -1, 1, 2, 3] {
                let j = anchor + off
                if lines.indices.contains(j) { consider(cut(lines[j], atAnyOf: payeeStops), at: j, distance: abs(off)) }
            }
        }
        guard let b = best else { return nil }
        return joinContinuation(b.name, lines, after: b.idx)
    }

    /// A long name often wraps to the next OCR line (e.g. "… Mukhaini B" +
    /// "Bahwan"). If the following line is a short alphabetic fragment, append
    /// it — dropping a trailing single-letter token left from the wrap.
    private static func joinContinuation(_ name: String, _ lines: [String], after index: Int) -> String {
        let next = index + 1
        guard next < lines.count else { return name }
        let cont = cleanName(cut(lines[next], atAnyOf: payeeStops))
        let lower = cont.lowercased()
        let words = cont.split(separator: " ").filter { $0.count >= 2 }
        guard (1...2).contains(words.count),
              cont.rangeOfCharacter(from: .decimalDigits) == nil,
              !nonNameWords.contains(where: { lower.contains($0) }) else { return name }
        var tokens = name.split(separator: " ").map(String.init)
        if let last = tokens.last, last.count == 1 { tokens.removeLast() }
        return (tokens + [cont]).joined(separator: " ")
    }

    /// The branch name is printed near the top, all-caps, distinct from the bank
    /// name and boilerplate.
    private static func branch(from lines: [String]) -> String? {
        for line in lines.prefix(10) where allCapsName(line) {
            let lower = line.lowercased()
            if printHeaderHints.contains(where: { lower.contains($0) }) { continue }
            return cleanName(line)
        }
        return nil
    }

    /// The account holder is printed (all-caps) lower on the cheque, near the
    /// account number — distinct from the branch line.
    private static func accountHolder(from lines: [String], branch: String?) -> String? {
        for line in lines where allCapsName(line) {
            let name = cleanName(line)
            let lower = line.lowercased()
            if name == branch { continue }
            if printHeaderHints.contains(where: { lower.contains($0) }) { continue }
            return name
        }
        return nil
    }

    private static let printHeaderHints = ["emirates", "bank", "cheque", "check", "licensed",
                                           "central", "p.j.s", "number", "date", "pay",
                                           "signature", "balance", "iban", "account"]

    /// True for an all-caps Latin line of ≥2 words (≥4 letters total, no digits,
    /// no lowercase) — the shape of a printed branch or account-holder name.
    private static func allCapsName(_ s: String) -> Bool {
        let latin = TextNormalization.stripArabic(s).trimmingCharacters(in: .whitespaces)
        guard latin.rangeOfCharacter(from: .decimalDigits) == nil,
              latin.rangeOfCharacter(from: .lowercaseLetters) == nil else { return false }
        let letters = latin.filter { $0.isLetter }.count
        let words = latin.split(separator: " ").filter { $0.count >= 2 }
        return letters >= 4 && words.count >= 2
    }

    /// Returns a cleaned name if `s` reads like one (≥2 alphabetic words, not
    /// boilerplate, not digit-heavy); otherwise nil.
    private static func plausibleName(_ s: String) -> String? {
        let name = cleanName(s)
        guard name.count >= 3 else { return nil }
        let lower = name.lowercased()
        if nonNameWords.contains(where: { lower.contains($0) }) { return nil }
        if s.filter(\.isNumber).count > 2 { return nil }
        let words = name.split(separator: " ").filter { $0.count >= 2 }
        return words.count >= 2 ? name : nil
    }

    private static func amountInWords(from lines: [String], lowerLines: [String]) -> String? {
        if let i = lowerLines.firstIndex(where: { $0.contains("only") }) {
            var start = i
            for j in stride(from: i, through: max(0, i - 2), by: -1) {
                if lowerLines[j].contains("dirhams") || lowerLines[j].contains("aed") { start = j; break }
            }
            return cleanWords(lines[start...i].joined(separator: " "))
        }
        if let i = lowerLines.firstIndex(where: { $0.contains("dirhams") }) {
            let after = afterToken("dirhams", in: lines[i])
            let words = cleanWords(after.isEmpty && i + 1 < lines.count ? lines[i + 1] : after)
            if words.count >= 3 { return words }
        }
        return nil
    }

    private static func amountInFigures(from lines: [String], excluding: Set<String>) -> String? {
        // 1) A number on a line carrying a currency marker (AED / Dhs / /- / ** / =).
        for raw in lines {
            let lower = raw.lowercased()
            guard lower.contains("aed") || raw.contains("/-") || raw.contains("**")
                    || raw.contains("=") || lower.contains("dhs") else { continue }
            if let a = TextNormalization.firstMatch(amountRegex, in: TextNormalization.normalizeDigits(raw)),
               !excluding.contains(a) { return a }
        }
        // 2) A thousands-grouped or decimal number anywhere (looks like money).
        for raw in lines {
            let s = TextNormalization.normalizeDigits(raw)
            if let m = TextNormalization.firstMatch(amountRegex, in: s), m.contains(",") || m.contains("."),
               !excluding.contains(m), m.filter({ $0.isNumber }).count >= 3 { return m }
        }
        // 3) A standalone integer in the amount box — a line that is essentially
        //    just digits (maybe trailed by /, -, * or =), 3–7 long, no leading
        //    zero (rules out cheque numbers like 000051) and not a known number.
        //    Several such fragments can appear (a split date, stub balances), so
        //    we score candidates by nearby context rather than taking the first.
        let amountCues = ["dirham", "aed", "dhs", "only", "amount", "/-", "/"]
        let badCues = ["date", "balance", "number", "account", "iban"]
        var best: (value: String, score: Int)?
        for (i, raw) in lines.enumerated() {
            let s = TextNormalization.normalizeDigits(raw)
                .trimmingCharacters(in: CharacterSet(charactersIn: " /-*=.").union(.whitespaces))
            guard s.count >= 3, s.count <= 7, s.allSatisfy(\.isNumber),
                  s.first != "0", !excluding.contains(s) else { continue }
            // Look at the line and its neighbours for context.
            let context = ((i - 1)...(i + 1))
                .filter { lines.indices.contains($0) }
                .map { lines[$0].lowercased() }
                .joined(separator: " ")
            var score = 0
            if amountCues.contains(where: { context.contains($0) }) { score += 2 }
            if badCues.contains(where: { context.contains($0) }) { score -= 3 }
            if best == nil || score > best!.score { best = (s, score) }
        }
        return best?.value
    }

    /// A MICR band we can trust for numbers: only digits and spaces survived
    /// OCR. Any leftover letters/symbols mean the E-13B transit marks were
    /// misread, so we must not treat them as part of a number.
    static func micrIsCleanDigits(_ micr: String) -> Bool {
        !micr.isEmpty && micr.allSatisfy { $0.isNumber || $0.isWhitespace }
    }

    /// Parse a MICR foot line into (chequeNumber, accountNumber). UAE/E-13B
    /// layout left→right is: cheque number · routing/sort code · account number
    /// · transaction code. We split on digit runs and assign by position/length.
    static func parseMICR(_ micr: String) -> (cheque: String?, account: String?) {
        let groups = micr
            .replacingOccurrences(of: "[^0-9 ⑆⑈⑇⑉:|<>]", with: " ", options: .regularExpression)
            .split(whereSeparator: { !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        guard !groups.isEmpty else { return (nil, nil) }
        let cheque = groups.first
        let account = Array(groups.dropFirst()).max(by: { $0.count < $1.count })
        return (cheque, account)
    }

    /// Parse a symbol-exact E-13B band (from `MICRReader`) into its fields.
    /// The routing number is the group bracketed by transit symbols ⑆…⑆; the
    /// group before it is the cheque number; the longest group after it is the
    /// account. Example: ⑈000051⑆402620152⑆⑈5275807201⑈.
    static func parseE13B(_ decoded: String)
        -> (cheque: String?, routing: String?, account: String?) {
        // Digit groups in order, each tagged with its delimiter symbols.
        var groups: [(digits: String, opener: Character?, closer: Character?)] = []
        var current = "", opener: Character?
        for ch in decoded {
            if ch.isNumber { current.append(ch) }
            else {
                if !current.isEmpty { groups.append((current, opener, ch)); current = "" }
                opener = ch
            }
        }
        if !current.isEmpty { groups.append((current, opener, nil)) }
        guard !groups.isEmpty else { return (nil, nil, nil) }

        guard let r = groups.firstIndex(where: { $0.opener == "⑆" && $0.closer == "⑆" }) else {
            // No transit pair — take the longest group as the account and a
            // shorter zero-padded one as the cheque number.
            let account = groups.map(\.digits).max { $0.count < $1.count }
            let cheque = groups.first(where: {
                (4...10).contains($0.digits.count) && $0.digits != account })?.digits
            return (cheque, nil, account)
        }
        let cheque = r > 0 ? groups[r - 1].digits : nil
        let account = groups.dropFirst(r + 1).map(\.digits).max { $0.count < $1.count }
        return (cheque, groups[r].digits, account)
    }

    private static func labelledNumber(_ labels: [String], in lines: [String],
                                       lowerLines: [String], digits: ClosedRange<Int>,
                                       includePrevious: Bool = false) -> String? {
        for (i, lower) in lowerLines.enumerated() {
            guard labels.contains(where: { lower.contains($0) }) else { continue }
            // The value can sit on the label line, the line after, or — when the
            // number is printed above its label (common on cheques) — the line
            // before. Check the label line first.
            var pool = [lines[i]]
            if i + 1 < lines.count { pool.append(lines[i + 1]) }
            if includePrevious, i - 1 >= 0 { pool.append(lines[i - 1]) }
            for candidate in pool {
                let onlyDigits = TextNormalization.normalizeDigits(candidate).filter { $0.isNumber }
                if digits.contains(onlyDigits.count) { return onlyDigits }
                if let run = longestDigitRun(in: candidate), digits.contains(run.count) { return run }
            }
        }
        return nil
    }

    /// The first line that is just a run of digits (after stripping spaces) of
    /// the given length — e.g. the cheque number printed alone at the top.
    private static func standaloneNumber(in lines: [String], length: ClosedRange<Int>) -> String? {
        for raw in lines {
            let s = TextNormalization.normalizeDigits(raw).filter { !$0.isWhitespace }
            if length.contains(s.count), s.allSatisfy(\.isNumber) { return s }
        }
        return nil
    }

    /// Maximal contiguous digit runs in `s` whose length is within `length`.
    private static func digitRuns(in s: String, length: ClosedRange<Int>) -> [String] {
        var runs: [String] = [], cur = ""
        for c in TextNormalization.normalizeDigits(s) {
            if c.isNumber { cur.append(c) }
            else { if length.contains(cur.count) { runs.append(cur) }; cur = "" }
        }
        if length.contains(cur.count) { runs.append(cur) }
        return runs
    }

    /// The cheque (serial) number: a 3–8 digit token scored by proximity to a
    /// cheque label, zero-padding (cheque numbers are zero-filled) and position
    /// near the top. The score gate demands more than position alone, so a
    /// stray address fragment can't win by default. Deliberately independent
    /// of the MICR band.
    private static func chequeNumber(from lines: [String], excluding: Set<String>) -> String? {
        var best: (value: String, score: Int)?
        let n = max(1, lines.count)
        for (i, line) in lines.enumerated() {
            for token in digitRuns(in: line, length: 3...8) where !excluding.contains(token) {
                let ctx = ([i - 1, i, i + 1]
                    .filter { lines.indices.contains($0) }
                    .map { lines[$0].lowercased() })
                    .joined(separator: " ")
                var score = 0
                // A *specific* cheque-number label nearby (not a bare "cheque",
                // which also appears in stub/body text like "…is Cheque").
                if ["cheque no", "cheque number", "eque no", "eque number", "chq",
                    "check no", "check number"]
                    .contains(where: { ctx.contains($0) }) { score += 4 }
                if token.first == "0" { score += 2 }                 // zero-padded serial
                if Double(i) < Double(n) * 0.4 { score += 1 }        // printed near the top
                if ctx.contains("account") || ctx.contains("iban")
                    || ctx.contains("balance") || ctx.contains("date") { score -= 4 }
                // Serials are printed standalone; digits glued to letters are a
                // security/code string (e.g. "WYyWXkAOhyK112DYkAlq"), not a serial.
                if let range = line.range(of: token) {
                    let before = range.lowerBound > line.startIndex
                        ? line[line.index(before: range.lowerBound)] : " "
                    let after = range.upperBound < line.endIndex ? line[range.upperBound] : " "
                    if before.isLetter || after.isLetter { score -= 3 }
                }
                if best == nil || score > best!.score { best = (token, score) }
            }
        }
        if let b = best, b.score >= 2 { return b.value }
        return nil
    }

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\b"#)

    /// The cheque date. Prefers a date next to a "Date" label and one with a
    /// 4-digit year, so a stray "10/12/85" fragment doesn't win over
    /// "Date 10/12/2025".
    private static func chequeDate(from lines: [String], lowerLines: [String]) -> String? {
        var best: (value: String, score: Int)?
        for (i, line) in lines.enumerated() {
            let normalized = TextNormalization.normalizeDigits(line)
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            dateRegex.enumerateMatches(in: normalized, range: range) { m, _, _ in
                guard let m, let whole = Range(m.range, in: normalized),
                      let dayRange = Range(m.range(at: 1), in: normalized),
                      let monthRange = Range(m.range(at: 2), in: normalized),
                      let yearRange = Range(m.range(at: 3), in: normalized) else { return }
                let value = String(normalized[whole])
                var score = 0
                let ctx = ([i - 1, i].filter { lines.indices.contains($0) }
                    .map { lines[$0].lowercased() }).joined(separator: " ")
                if ctx.contains("date") { score += 3 }
                if normalized[yearRange].count == 4 { score += 2 }
                // A calendar-valid day/month beats an OCR-mangled one (e.g. a
                // month read as "19"): prefer 10/12/2025 over 10/19/2025.
                if let d = Int(normalized[dayRange]), let mo = Int(normalized[monthRange]),
                   (1...31).contains(d), (1...12).contains(mo) { score += 2 }
                if best == nil || score > best!.score { best = (value, score) }
            }
        }
        return best?.value ?? TextNormalization.detectDates(in: lines.joined(separator: "\n")).first
    }

    /// Derive the account number from a UAE IBAN: drop "AE", the 2 check digits
    /// and the 3-digit bank code, then strip leading zeros from the BBAN.
    private static func ibanTailAccount(_ iban: String?) -> String? {
        guard let iban, iban.count > 7 else { return nil }
        let bban = iban.dropFirst(2)                 // drop "AE"
        guard bban.count > 5 else { return nil }
        let account = String(bban.dropFirst(5))      // drop 2 check + 3 bank-code
        let trimmed = String(account.drop(while: { $0 == "0" }))
        return trimmed.count >= 5 ? trimmed : (account.isEmpty ? nil : account)
    }

    // MARK: - String utilities

    private static func cut(_ s: String, atAnyOf stops: [String]) -> String {
        let lower = s.lowercased()
        var end = s.endIndex
        for stop in stops {
            if let r = lower.range(of: stop), r.lowerBound < end {
                end = s.index(s.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            }
        }
        return String(s[s.startIndex..<end])
    }

    private static func afterToken(_ token: String, in s: String) -> String {
        let lower = s.lowercased()
        guard let r = lower.range(of: token) else { return s }
        return String(s[r.upperBound...])
    }

    private static let nameExtras: Set<Character> = [" ", ".", "&", "-", "/"]
    private static func cleanName(_ s: String) -> String {
        // Treat underscores/commas as word separators so "Al_Mukhaini, Bak"
        // becomes "Al Mukhaini Bak" rather than merging tokens.
        let stripped = TextNormalization.stripArabic(s)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let kept = stripped.filter { $0.isLetter || nameExtras.contains($0) }
        return kept.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-/&"))
    }

    private static func cleanWords(_ s: String) -> String {
        let stripped = TextNormalization.stripArabic(s)
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: " :;-_*=|/\\").union(.whitespacesAndNewlines))
    }

    private static func longestDigitRun(in s: String) -> String? {
        let digits = TextNormalization.normalizeDigits(s)
        var best = "", cur = ""
        for c in digits {
            if c.isNumber { cur.append(c); if cur.count > best.count { best = cur } }
            else { cur = "" }
        }
        return best.isEmpty ? nil : best
    }
}
