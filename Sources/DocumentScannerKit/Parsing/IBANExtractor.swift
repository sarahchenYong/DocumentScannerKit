//
//  IBANExtractor.swift
//  DocumentScannerKit
//
//  Finds an IBAN in OCR lines — any ISO 13616 country, labelled ("IBAN:
//  AE…") or bare, printed in 4-character groups, wrapped across two lines,
//  or handwritten on plain paper. Every candidate is cut to its country's
//  registered length and proven by the mod-97 check digits; when a raw
//  reading fails, the extractor retries with the classic OCR/handwriting
//  letter-for-digit confusions (O→0, I/L→1, S→5, B→8, Z→2, G→6) repaired,
//  so a hand-drawn zero read as "O" still yields the true, validated IBAN.
//

import Foundation

public enum IBANExtractor {

    /// ISO 13616 registry: country code → total IBAN length. A two-letter
    /// prefix outside this table is ordinary text, never an IBAN.
    static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16,
        "BG": 22, "BH": 22, "BI": 27, "BR": 29, "BY": 28, "CH": 21, "CR": 22,
        "CY": 28, "CZ": 24, "DE": 22, "DJ": 27, "DK": 18, "DO": 28, "EE": 20,
        "EG": 29, "ES": 24, "FI": 18, "FK": 18, "FO": 18, "FR": 27, "GB": 22,
        "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HN": 28, "HR": 21,
        "HU": 28, "IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30,
        "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20, "LU": 20,
        "LV": 21, "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MN": 20,
        "MR": 27, "MT": 31, "MU": 30, "NI": 28, "NL": 18, "NO": 15, "OM": 23,
        "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22,
        "RU": 33, "SA": 24, "SC": 31, "SD": 18, "SE": 24, "SI": 19, "SK": 24,
        "SM": 27, "SO": 23, "ST": 25, "SV": 28, "TL": 23, "TN": 24, "TR": 26,
        "UA": 29, "VA": 22, "VG": 24, "XK": 20, "YE": 30,
    ]

    /// Letters Vision (and handwriting) habitually returns for digits.
    private static let digitConfusions: [Character: Character] = [
        "O": "0", "Q": "0", "I": "1", "L": "1", "S": "5", "B": "8",
        "Z": "2", "G": "6",
    ]

    /// The IBAN a parsed document carries: the field the parser labelled
    /// while classifying it, or — for a page with no layout to label one (a
    /// plain bank letter, a statement, a handwritten note) — the best
    /// validated candidate in everything the page said. Blank readings count
    /// as none, so a caller can treat nil as "this document has no IBAN",
    /// whether it was scanned live or picked from Photos or Files.
    public static func extract(from document: ScannedDocument) -> String? {
        let value = document.iban ?? extract(from: document.rawText)?.value
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// The best IBAN in the lines, with a confidence reflecting how it was
    /// proven: mod-97-valid 0.95 (or 0.9 after a confusion repair), an exact
    /// country-length shape whose check digits couldn't be validated 0.6.
    public static func extract(from lines: [String]) -> (value: String, confidence: Double)? {
        // Search each line and each adjacent pair (an IBAN often wraps at a
        // group boundary), remembering whether an "IBAN" label was nearby.
        var searches: [(text: String, labelled: Bool, joined: Bool)] = []
        for (i, line) in lines.enumerated() {
            let labelled = line.lowercased().contains("iban")
                || (i > 0 && lines[i - 1].lowercased().contains("iban"))
            searches.append((line, labelled, false))
            if i + 1 < lines.count {
                searches.append((line + lines[i + 1],
                                 labelled || lines[i + 1].lowercased().contains("iban"),
                                 true))
            }
        }

        var best: (value: String, valid: Bool, repaired: Bool, labelled: Bool)?
        var seen = Set<String>()
        for search in searches {
            for c in candidates(in: search.text) {
                // A wrap-join fabricates contiguity across two lines that may
                // have nothing to do with each other — "Premises No 1234567"
                // followed by "Total due AED 412.90" reads as a Norwegian
                // IBAN by shape alone. Only the checksum can prove a joined
                // candidate; a wrapped IBAN that really is one still passes.
                guard c.valid || !search.joined else { continue }
                guard seen.insert(c.value).inserted || c.valid else { continue }
                let candidate = (c.value, c.valid, c.repaired, search.labelled)
                if best == nil || outranks(candidate, best!) { best = candidate }
            }
        }
        guard let best else { return nil }
        return (best.value, best.valid ? (best.repaired ? 0.9 : 0.95) : 0.6)
    }

    /// True when `a` should replace `b`: checksum proof first, then an
    /// unrepaired reading, then label proximity.
    private static func outranks(_ a: (value: String, valid: Bool, repaired: Bool, labelled: Bool),
                                 _ b: (value: String, valid: Bool, repaired: Bool, labelled: Bool)) -> Bool {
        if a.valid != b.valid { return a.valid }
        if a.repaired != b.repaired { return b.repaired }
        if a.labelled != b.labelled { return a.labelled }
        return false
    }

    /// Every candidate in `text`: compact to alphanumerics, then try each
    /// registered country code as a starting point and cut to that country's
    /// length. Positional scanning (not regex) so a label glued to the value
    /// ("IBANAE07…") or a lookalike prefix ("BA" inside "IBAN AE…") can never
    /// swallow the real candidate. A candidate must be printed contiguously —
    /// its characters may straddle group separators (space, dash, dot) but
    /// never other punctuation or other words: prose that happens to start
    /// with a country code ("…march 2026 total AED 12,345.67") is not an IBAN
    /// even when mod-97 gets lucky.
    private static func candidates(in text: String)
        -> [(value: String, valid: Bool, repaired: Bool)] {
        let chars = Array(TextNormalization.normalizeDigits(text).uppercased())
        var compact: [Character] = []
        var source: [Int] = []
        for (index, ch) in chars.enumerated() where ch.isLetter || ch.isNumber {
            compact.append(ch)
            source.append(index)
        }
        guard compact.count >= 15 else { return [] }   // shortest IBAN (NO) is 15

        var out: [(String, Bool, Bool)] = []
        for i in 0..<(compact.count - 3) {
            guard compact[i].isLetter, compact[i + 1].isLetter else { continue }
            let country = String(compact[i...(i + 1)])
            guard let length = ibanLengths[country], i + length <= compact.count else { continue }
            let span = chars[source[i]...source[i + length - 1]]
            guard span.allSatisfy({ $0.isLetter || $0.isNumber || " -.".contains($0) })
            else { continue }
            if let c = validate(Array(compact[i..<(i + length)])) { out.append(c) }
        }
        return out
    }

    /// Prove one length-exact candidate. Tries the raw reading, then check
    /// digits repaired, then every confusable letter repaired — first mod-97
    /// pass wins. With no pass, the shape is kept only when the repaired
    /// reading actually looks like an IBAN body (digit check digits, at most
    /// six letters — real BBANs are digit-heavy; GB's four-letter bank code
    /// is the common ceiling).
    private static func validate(_ chars: [Character])
        -> (value: String, valid: Bool, repaired: Bool)? {
        let raw = String(chars)
        var checkRepaired = chars
        for i in 2...3 { checkRepaired[i] = digitConfusions[checkRepaired[i]] ?? checkRepaired[i] }
        var fullRepaired = checkRepaired
        for i in 4..<fullRepaired.count {
            fullRepaired[i] = digitConfusions[fullRepaired[i]] ?? fullRepaired[i]
        }

        // Real check digits are always digits — a letter there is either a
        // repairable OCR confusion or proof this is not an IBAN, so a lucky
        // mod-97 pass with letter check digits never counts.
        func checksumValid(_ s: [Character]) -> Bool {
            s[2].isNumber && s[3].isNumber && mod97(String(s)) == 1
        }
        if checksumValid(chars) { return (raw, true, false) }
        for variant in [checkRepaired, fullRepaired] where String(variant) != raw {
            if checksumValid(variant) { return (String(variant), true, true) }
        }

        // No checksum pass — a handwriting misread of a real digit can't be
        // repaired by letter mapping. Keep the shape as a low-confidence
        // fallback when it's unmistakably IBAN-like.
        let shape = String(checkRepaired)
        let body = Array(shape)
        guard body[2].isNumber, body[3].isNumber,
              body.dropFirst(4).filter({ $0.isLetter }).count <= 6 else { return nil }
        return (shape, false, false)
    }

    /// ISO 7064 mod-97: rearrange (BBAN + country + check digits), map
    /// letters to 10…35, and the remainder must be 1. Nil for any character
    /// that can't participate.
    static func mod97(_ iban: String) -> Int? {
        guard iban.count >= 5 else { return nil }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            if ch.isNumber, let d = ch.wholeNumberValue {
                remainder = (remainder * 10 + d) % 97
            } else if ch.isLetter, let ascii = ch.asciiValue, (65...90).contains(ascii) {
                remainder = (remainder * 100 + Int(ascii) - 55) % 97
            } else {
                return nil
            }
        }
        return remainder
    }
}
