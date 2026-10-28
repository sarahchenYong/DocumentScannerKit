//
//  AddressExtractor.swift
//  DocumentScannerKit
//
//  Address-specific heuristics shared by bills, cards, passport back pages,
//  and short handwritten notes. OCR does not expose handwriting separately,
//  so confidence reflects how explicit the address layout is, not penmanship.
//

import Foundation

enum AddressExtractor {
    private static let labels = ["address", "residential address", "mailing address",
                                 "billing address", "service address", "premise address",
                                 "delivery address", "deliver to", "addr"]

    /// Label wordings that name the OCCUPANT's address specifically — on a
    /// whole-document scan these outrank a bare "Address" the sender/issuer
    /// printed about itself (a letterhead, a bank's footer).
    private static let specificLabels = ["residential address", "service address",
                                         "permanent address", "present address",
                                         "current address", "home address",
                                         "mailing address", "billing address",
                                         "delivery address", "premise address"]
    private static let streetWords = ["street", "st", "road", "rd", "avenue", "ave", "lane", "ln",
                                      "boulevard", "blvd", "building", "bldg", "tower", "office", "villa", "flat",
                                      "apartment", "apt", "floor", "po box", "p.o. box", "sector", "district",
                                      "plot", "block", "house", "area", "community", "zone", "landmark",
                                      "near", "opposite", "opp", "behind"]
    private static let placeWords: Set<String> = {
        let locale = Locale(identifier: "en_US")
        let countryNames = Locale.isoRegionCodes.compactMap { locale.localizedString(forRegionCode: $0)?.lowercased() }
        // Emirates and major UAE cities count as location cues too — a
        // handwritten "Al Barsha, Dubai" rarely bothers naming the country.
        let uaePlaces = ["dubai", "abu dhabi", "sharjah", "ajman", "fujairah",
                         "ras al khaimah", "umm al quwain", "al ain", "deira"]
        return Set(countryNames + uaePlaces
                   + ["uae", "u.a.e", "usa", "u.s.a", "uk", "u.k", "ua", "united arab emirates"])
    }()
    private static let stopWords = ["account number", "customer number", "invoice number", "bill number",
                                    "amount due", "total due", "issue date", "due date", "passport no",
                                    "date of birth", "father's name", "mother's name", "spouse",
                                    "place of issue", "email", "e-mail", "telephone", "mobile", "www.",
                                    // Billing-summary wording that interleaves the address block on a
                                    // full-page bill scan (two-column layouts OCR out of order).
                                    "previous bill", "current month", "adjustment", "payments received",
                                    "bill summary", "tax invoice", "additional charges",
                                    // Premise metadata sits right next to the real PO Box/city/country
                                    // line on a DEWA-style bill; "FLAT" in "RESIDENTIAL - FLAT" would
                                    // otherwise read as the street word "flat" and let this line borrow
                                    // the real address's location evidence via the wider run window below.
                                    "premise number", "premise type"]
    /// Passport back pages often put this immediately after the address. OCR
    /// occasionally reads "issue" as "isue", so accept the missing `s` too.
    private static let passportIssueStopPattern = #"\b(?:date\s+(?:and|&)\s+)?place\s+of\s+is+u\w*\b|\bdate\s+(?:and|&)\s+place\b"#
    private static let trailingPhonePattern = #"\s*(?:\||/)\s*(?:(?:tel(?:ephone)?|phone|mobile)\s*:?[[:space:]]*)?\+?\d[\d\s().-]{5,}$"#

    static func extract(from lines: [String]) -> (value: String, confidence: Double)? {
        let clean = lines.map { addressOnly(TextNormalization.sanitizeValue($0)) }
        guard !clean.isEmpty else { return nil }

        // Labelled: a whole-document scan can carry several "Address" labels
        // (the issuer's letterhead, the customer block…) — build the block
        // under EVERY label and keep the best-evidenced one, preferring
        // occupant-specific wordings ("Residential/Service/Home Address").
        var bestLabelled: (value: String, score: Int)?
        for labelIndex in clean.indices where containsLabel(clean[labelIndex]) {
            var parts = valueOnLabelLine(clean[labelIndex])
            for i in (labelIndex + 1)..<min(clean.count, labelIndex + 5) {
                let line = clean[i]
                if line.isEmpty || containsStopWord(line) || containsLabel(line) { break }
                if !parts.isEmpty || looksLikeAddress(line) { parts.append(line) }
            }
            guard let value = joined(parts) else { continue }
            let lower = clean[labelIndex].lowercased()
            let score = addressEvidence(in: value)
                + (specificLabels.contains(where: { lower.contains($0) }) ? 3 : 0)
            if bestLabelled == nil || score > bestLabelled!.score {
                bestLabelled = (value, score)
            }
        }
        if let bestLabelled { return (bestLabelled.value, 0.86) }

        // Unlabelled cards and handwritten notes: accept only a run with both
        // a location cue and a street/building or numeric cue — and when a
        // whole document offers several such runs, keep the best-evidenced.
        var bestRun: (value: String, score: Int)?
        for i in clean.indices where looksLikeAddress(clean[i]) {
            var parts = [clean[i]]
            // A house/villa/unit number often sits on its own line right
            // before the street name ("2176" then "John Avenue") — OCR and
            // handwriting alike rarely combine the two. Prepend it so it
            // isn't dropped outright for lacking the letters looksLikeAddress
            // requires of an anchor.
            if i > 0, isBareUnitNumber(clean[i - 1]) {
                parts.insert(clean[i - 1], at: 0)
            }
            // A business card commonly uses three consecutive lines (office
            // name, floor/building, then city/country); a handwritten note
            // or a street/area/city/country block can run longer. Keep the
            // window as wide as the labelled case above so the country line
            // is never dropped just for sitting a couple of lines further
            // down — addressEvidence(), not line count, decides the winner.
            for next in (i + 1)..<min(clean.count, i + 5)
                where looksLikeAddressContinuation(clean[next]) {
                parts.append(clean[next])
            }
            if let value = joined(parts), hasLocationAndDetail(value) {
                let score = addressEvidence(in: value)
                if bestRun == nil || score > bestRun!.score { bestRun = (value, score) }
            }
        }
        if let bestRun { return (bestRun.value, 0.65) }

        // Handwritten note on a sparse page: no label, no recognizable
        // city/country — accept a compact run anchored on an explicit street
        // word. Confidence is low on purpose; the caller decides whether a
        // low-evidence address is worth prefilling.
        let contentLines = clean.filter { !$0.isEmpty }.count
        guard contentLines <= 8 else { return nil }
        for i in clean.indices where hasStreetWord(clean[i]) && !containsLabel(clean[i]) {
            let anchor = clean[i]
            var parts = [anchor]
            if i > 0, isBareUnitNumber(clean[i - 1]) {
                parts.insert(clean[i - 1], at: 0)
            }
            for next in (i + 1)..<min(clean.count, i + 5)
                where looksLikeAddressContinuation(clean[next]) {
                parts.append(clean[next])
            }
            let multiLine = parts.count >= 2
            // Use the anchor line itself, not parts[0] — a prepended unit
            // number would otherwise be checked for street words it was
            // never expected to carry.
            let detailedSingle = streetWordCount(in: anchor) >= 2
                && anchor.rangeOfCharacter(from: .decimalDigits) != nil
            if let value = joined(parts), multiLine || detailedSingle {
                return (value, 0.55)
            }
        }
        return nil
    }

    /// A short, bare digits-only line ("2176") reads as a house/villa/unit
    /// number when it sits next to a street line — never on its own, since
    /// an account/invoice number is typically longer and always has other
    /// context around it that already excludes it (see `stopWords`).
    private static func isBareUnitNumber(_ line: String) -> Bool {
        let digits = line.filter(\.isNumber)
        return !line.isEmpty && digits.count == line.count && (1...6).contains(digits.count)
    }

    /// How address-like a block reads: street/building words (capped so a
    /// word-list can't dominate), a known place, and a house/flat number.
    private static func addressEvidence(in value: String) -> Int {
        var score = min(streetWordCount(in: value), 3)
        let lower = value.lowercased()
        if placeWords.contains(where: { lower.contains($0) }) { score += 2 }
        if value.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        // A block that ends in a place name reads as a complete, correctly
        // terminated "…, city, country" address. One that merely mentions a
        // place mid-block — a widened window can catch a country word that
        // sits a couple of unrelated lines above the real street line — is
        // weaker evidence, so it should not out-score the properly ordered
        // run once both already cleared the street/place/number bar above.
        if let lastComponent = lower.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
           placeWords.contains(lastComponent) {
            score += 1
        }
        // A run that leads with a bare number ("2176, John Avenue…") reads
        // as a house/unit number properly anchoring the street that follows
        // — stronger, more specific evidence than a digit merely appearing
        // somewhere inside the block (already scored above).
        if let firstComponent = value.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
           isBareUnitNumber(firstComponent) {
            score += 1
        }
        return score
    }

    private static func hasStreetWord(_ line: String) -> Bool {
        !containsStopWord(line) && streetWordCount(in: line) >= 1
    }

    private static func streetWordCount(in value: String) -> Int {
        let lower = value.lowercased()
        return streetWords.filter { containsAddressWord($0, in: lower) }.count
    }

    private static func containsLabel(_ line: String) -> Bool {
        let lower = line.lowercased()
        return labels.contains { lower.contains($0) }
    }

    private static func valueOnLabelLine(_ line: String) -> [String] {
        let lower = line.lowercased()
        guard let label = labels.first(where: { lower.range(of: $0) != nil }),
              let range = lower.range(of: label) else { return [] }
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        let index = line.index(line.startIndex, offsetBy: offset)
        let value = TextNormalization.sanitizeValue(String(line[index...]))
        return looksLikeAddressContinuation(value) ? [value] : []
    }

    private static func looksLikeAddress(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard !containsStopWord(line), !isAmountLine(line), lower.count >= 4 else { return false }
        return streetWords.contains { word in containsAddressWord(word, in: lower) }
            || placeWords.contains { lower.contains($0) }
            || (lower.rangeOfCharacter(from: .decimalDigits) != nil && lower.rangeOfCharacter(from: .letters) != nil)
    }

    private static func looksLikeAddressContinuation(_ line: String) -> Bool {
        !containsStopWord(line) && !isAmountLine(line)
            && (looksLikeAddress(line) || line.rangeOfCharacter(from: .letters) != nil)
    }

    /// A currency amount ("Đ596.27", "B 246.25", "AED 380.50" reads as
    /// digits-with-decimals and almost no letters once the dirham symbol is
    /// OCR-mangled). Amounts satisfy the digits+letters address cue, so they
    /// must be ruled out explicitly.
    private static func isAmountLine(_ line: String) -> Bool {
        guard line.range(of: #"\d+[.,]\d{2}\b"#, options: .regularExpression) != nil else { return false }
        return line.filter { $0.isLetter }.count <= 3
    }

    private static func containsStopWord(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Match the short phone label as a complete word so building names such
        // as "H Hotel Office Tower" are not mistaken for contact details.
        if lower.range(of: #"\btel\b"#, options: .regularExpression) != nil {
            return true
        }
        // A bare, unlabelled email address (very common on the line right
        // after a business card's address block) is never itself part of a
        // street address, and it carries no "email:" label to catch above.
        if lower.contains("@") {
            return true
        }
        return stopWords.contains { lower.contains($0) }
            || lower.range(of: passportIssueStopPattern, options: .regularExpression) != nil
    }

    /// Keep the part preceding a known non-address field when OCR merges both
    /// visual lines into one string (common on passport address pages).
    private static func addressOnly(_ line: String) -> String {
        var end = line.endIndex

        for stopWord in stopWords {
            if let range = line.range(of: stopWord, options: .caseInsensitive), range.lowerBound < end {
                end = range.lowerBound
            }
        }
        if let range = line.range(of: passportIssueStopPattern, options: .regularExpression), range.lowerBound < end {
            end = range.lowerBound
        }
        if let range = line.range(of: trailingPhonePattern, options: .regularExpression), range.lowerBound < end {
            end = range.lowerBound
        }

        var address = String(line[..<end]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",;:-|")))

        address = removingTrailingOCRNoise(afterPostalCodeIn: address)
        return address
    }

    /// Postal codes take many shapes worldwide, so do not maintain a
    /// country-specific regex. When OCR has merged a later labelled field into
    /// an address, use the final compact, alphanumeric address component as a
    /// boundary and discard only the comma-separated noise after it.
    private static func removingTrailingOCRNoise(afterPostalCodeIn address: String) -> String {
        let parts = address.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let postalIndex = parts.lastIndex(where: isLikelyPostalCode), postalIndex < parts.count - 1 else {
            return address
        }
        return parts[...postalIndex].joined(separator: ", ")
    }

    private static func isLikelyPostalCode(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard (3...12).contains(compact.count),
              compact.rangeOfCharacter(from: .decimalDigits) != nil,
              compact.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }
        // A post code is a compact code, not a street/building description.
        return !streetWords.contains { value.lowercased().contains($0) }
    }

    private static func hasLocationAndDetail(_ value: String) -> Bool {
        let lower = value.lowercased()
        let location = placeWords.contains { lower.contains($0) }
        let detail = streetWords.contains { containsAddressWord($0, in: lower) }
            || (lower.rangeOfCharacter(from: .decimalDigits) != nil && lower.rangeOfCharacter(from: .letters) != nil)
        return location && detail
    }

    /// Address words must be complete words so ordinary text is never an
    /// address — "statement" is not "st", "nearly" is not "near", and a
    /// "warehouse" is not a "house".
    private static func containsAddressWord(_ word: String, in line: String) -> Bool {
        line.range(of: #"\b\#(word)\b"#, options: .regularExpression) != nil
    }

    private static func joined(_ parts: [String]) -> String? {
        // Each part is an OCR line and may already end in a comma ("Lansing,").
        // Strip that boundary punctuation before adding our own ", " separator,
        // otherwise adjacent parts double up into "Lansing, , Michigan".
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))) }
        let unique = trimmed.filter { !$0.isEmpty }.reduce(into: [String]()) { out, value in
            if !out.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { out.append(value) }
        }
        guard !unique.isEmpty else { return nil }
        return unique.joined(separator: ", ")
    }
}
