//
//  FieldExtractor.swift
//  DocumentScannerKit
//
//  Pulls labeled fields out of recognized text for documents without (or in
//  addition to) an MRZ — IDs, licences, residence permits. For each field we
//  locate the label, then search outward (nearest lines first, both directions)
//  for a value matching the field's expected kind. This handles bilingual
//  two-column cards where a value sits several lines from its label and the
//  lines arrive out of reading order.
//

import Foundation

enum FieldExtractor {

    /// The kind of value a field expects — so a leftover label word ("Date")
    /// is never mistaken for a real value.
    enum ValueKind { case date, idNumber, number, postalCode, text }

    struct Spec {
        let patterns: [String]
        let key: ScannedFieldKey
        let label: String
        let category: FieldCategory
        let kind: ValueKind
    }

    /// Field definitions; order matters — more specific labels first.
    static let specs: [Spec] = [
        Spec(patterns: ["driving licence no", "driving license no", "licence no", "license no",
                        "licence number", "license number", "dl no"],
             key: .licenseNumber, label: "Licence No", category: .vehicle, kind: .idNumber),
        Spec(patterns: ["passport no", "passport number"],
             key: .passportNumber, label: "Passport No", category: .document, kind: .idNumber),
        Spec(patterns: ["card number", "card no"],
             key: .cardNumber, label: "Card Number", category: .document, kind: .idNumber),
        Spec(patterns: ["permanent account number", "pan number", "pan no", "pan card"],
             key: .nationalIDNumber, label: "PAN Number", category: .document, kind: .idNumber),
        Spec(patterns: ["id number", "identity no", "id no", "uid", "emirates id"],
             key: .emiratesIDNumber, label: "ID Number", category: .document, kind: .idNumber),
        Spec(patterns: ["file number", "file no", "u.i.d", "unified no", "unified number"],
             key: .fileNumber, label: "File Number", category: .document, kind: .idNumber),
        // Address labels are deliberately specific. They cover documents from
        // any country without relying on a country-specific layout.
        Spec(patterns: ["postal code", "postcode", "zip code", "zip", "pin code", "pincode"],
             key: .postalCode, label: "Postal Code", category: .address, kind: .postalCode),
        // Deliberately NOT "road"/"avenue"/"boulevard" as bare patterns:
        // those words are common inside a real address value itself
        // ("Sheikh Zayed Road", "Al Wasl Avenue"), so treating them as a
        // label ("Avenue" -> everything after it is the "value") mistakes
        // the address for a labelled field and corrupts it. Bare "street"
        // stays — "Street: Musterstraße 12" is a genuine, common label —
        // unlabelled street text is recognised by AddressExtractor instead.
        Spec(patterns: ["street address", "address line", "street"],
             key: .street, label: "Street", category: .address, kind: .text),
        Spec(patterns: ["state/province", "state", "province", "region", "county"],
             key: .stateOrProvince, label: "State / Province", category: .address, kind: .text),
        Spec(patterns: ["city", "town", "locality", "municipality"],
             key: .city, label: "City", category: .address, kind: .text),
        Spec(patterns: ["country"],
             key: .country, label: "Country", category: .address, kind: .text),
        Spec(patterns: ["trade name", "company name", "business name"],
             key: .tradeName, label: "Trade Name", category: .business, kind: .text),
        Spec(patterns: ["legal type", "legal form", "legal status"],
             key: .legalForm, label: "Legal Type", category: .business, kind: .text),
        Spec(patterns: ["license activity", "licence activity", "business activity",
                        "activities", "activity"],
             key: .businessActivity, label: "Activity", category: .business, kind: .text),
        Spec(patterns: ["commercial register no", "commercial registration no",
                        "commercial register", "registration no", "register no"],
             key: .registrationNumber, label: "Registration No", category: .business, kind: .number),
        Spec(patterns: ["date of birth", "d.o.b", "dob"],
             key: .dateOfBirth, label: "Date of Birth", category: .personal, kind: .date),
        Spec(patterns: ["date of issue", "issuing date", "issue date", "date of issuance", "doi"],
             key: .dateOfIssue, label: "Issue Date", category: .document, kind: .date),
        Spec(patterns: ["date of expiry", "expiry date", "date of expiration", "valid till", "valid upto", "valid up to", "expiry"],
             key: .dateOfExpiry, label: "Expiry Date", category: .document, kind: .date),
        Spec(patterns: ["place of birth", "birth place"],
             key: .placeOfBirth, label: "Place of Birth", category: .personal, kind: .text),
        Spec(patterns: ["father's name", "fathers name", "father name", "s/o"],
             key: .fathersName, label: "Father's Name", category: .personal, kind: .text),
        Spec(patterns: ["mother's name", "mothers name", "mother name"],
             key: .mothersName, label: "Mother's Name", category: .personal, kind: .text),
        Spec(patterns: ["spouse", "husband name", "wife name", "w/o"],
             key: .spouseName, label: "Spouse", category: .personal, kind: .text),
        Spec(patterns: ["full name", "holder name", "name"],
             key: .fullName, label: "Name", category: .personal, kind: .text),
        Spec(patterns: ["nationality"],
             key: .nationality, label: "Nationality", category: .personal, kind: .text),
        Spec(patterns: ["sex", "gender"],
             key: .sex, label: "Sex", category: .personal, kind: .text),
        Spec(patterns: ["occupation", "profession"],
             key: .occupation, label: "Occupation", category: .travel, kind: .text),
        Spec(patterns: ["employer", "sponsor"],
             key: .employer, label: "Employer / Sponsor", category: .travel, kind: .text),
        Spec(patterns: ["place of issue", "issuing place", "issued at"],
             key: .placeOfIssue, label: "Place of Issue", category: .document, kind: .text),
        Spec(patterns: ["issuing authority", "authority"],
             key: .issuingAuthority, label: "Issuing Authority", category: .document, kind: .text),
        Spec(patterns: ["blood group", "blood"],
             key: .bloodGroup, label: "Blood Group", category: .personal, kind: .text),
    ]

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}|\d{4}[/.\-]\d{1,2}[/.\-]\d{1,2})\b"#)
    private static let idRegex = try! NSRegularExpression(
        pattern: #"(\d{3}-\d{4}-\d{7}-\d|(?=[A-Z0-9\-]*\d)[A-Z0-9][A-Z0-9\-]{4,}[A-Z0-9])"#)   // an ID number always carries a digit
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d{4,12}\b"#)
    private static let panRegex = try! NSRegularExpression(pattern: #"\b[A-Z]{5}[0-9]{4}[A-Z]\b"#)

    static func extract(from lines: [String]) -> [ScannedField] {
        var out: [ScannedField] = []
        var usedKeys = Set<ScannedFieldKey>()
        var usedValues = Set<String>()
        let window = 4

        for spec in specs where !usedKeys.contains(spec.key) {
            guard let i = lines.firstIndex(where: { line in
                let lower = line.lowercased()
                return spec.patterns.contains { p in
                    guard let r = lower.range(of: p) else { return false }
                    return lower.distance(from: lower.startIndex, to: r.lowerBound) <= 3
                }
            }) else { continue }

            var candidates: [String] = []
            let lower = lines[i].lowercased()
            if let p = spec.patterns.first(where: { lower.range(of: $0) != nil }),
               let r = lower.range(of: p) {
                let afterIdx = lines[i].index(lines[i].startIndex,
                                              offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))
                candidates.append(String(lines[i][afterIdx...]))
            }
            for d in 1...window {
                if i - d >= 0 { candidates.append(lines[i - d]) }
                if i + d < lines.count { candidates.append(lines[i + d]) }
            }

            for candidate in candidates {
                guard let value = extractValue(spec.kind, from: candidate),
                      !usedValues.contains(value.lowercased()) else { continue }
                out.append(ScannedField(key: spec.key, label: spec.label,
                                        value: value, category: spec.category,
                                        confidence: 0.8))          // labelled value
                usedKeys.insert(spec.key)
                usedValues.insert(value.lowercased())
                break
            }
        }

        // --- Format-based detection for sparse/unlabeled documents ---

        // Addresses are often multi-line, especially on utility bills and
        // handwritten pages. Extract them as one value after the ordinary
        // labelled fields so a nearby person/company name is not mistaken for
        // the address. This also covers an unlabelled address on a business
        // card when its street/city pattern is strong enough.
        if !usedKeys.contains(.address), let address = AddressExtractor.extract(from: lines) {
            out.append(ScannedField(key: .address, label: "Address", value: address.value,
                                    category: .address, confidence: address.confidence))
            usedKeys.insert(.address)
        }

        // An IBAN anywhere on the document — labelled ("IBAN: AE…") or bare,
        // printed or handwritten, any ISO 13616 country — validated against
        // the country's registered length and the mod-97 check digits. Bank
        // letters, statements, and plain notes all surface it this way;
        // cheques get theirs from ChequeParser.
        if !usedKeys.contains(.iban), let iban = IBANExtractor.extract(from: lines) {
            out.append(ScannedField(key: .iban, label: "IBAN", value: iban.value,
                                    category: .banking, confidence: iban.confidence))
            usedKeys.insert(.iban)
            usedValues.insert(iban.value.lowercased())
        }

        // Indian PAN by its unique shape, even if the label was missed.
        if !usedKeys.contains(.nationalIDNumber) {
            for line in lines {
                if let pan = TextNormalization.firstMatch(panRegex, in: line.uppercased()),
                   !usedValues.contains(pan.lowercased()) {
                    out.append(ScannedField(key: .nationalIDNumber, label: "PAN Number",
                                            value: pan, category: .document,
                                            confidence: 0.9))      // strict format match
                    usedKeys.insert(.nationalIDNumber); usedValues.insert(pan.lowercased())
                    break
                }
            }
        }

        // A PAN card prints holder/father names in ALL-CAPS with no label.
        if usedKeys.contains(.nationalIDNumber), !usedKeys.contains(.fullName) {
            let headerHints = ["govt", "government", "income", "tax", "permanent",
                               "account", "department", "signature", "india"]
            let nameLines = lines.filter { line in
                let lower = line.lowercased()
                if headerHints.contains(where: { lower.contains($0) }) { return false }
                if line.range(of: "[0-9]", options: .regularExpression) != nil { return false }
                if line.range(of: "[a-z]", options: .regularExpression) != nil { return false }
                if line.range(of: "[A-Z]", options: .regularExpression) == nil { return false }
                return line.filter { $0.isLetter }.count >= 4
            }
            if let name = nameLines.first {
                out.append(ScannedField(key: .fullName, label: "Name",
                                        value: TextNormalization.sanitizeValue(name), category: .personal,
                                        confidence: 0.65))         // positional guess
                usedKeys.insert(.fullName)
            }
            if nameLines.count >= 2 {
                out.append(ScannedField(key: .fathersName, label: "Father's Name",
                                        value: TextNormalization.sanitizeValue(nameLines[1]), category: .personal,
                                        confidence: 0.65))         // positional guess
            }
        }

        return out
    }

    private static func extractValue(_ kind: ValueKind, from raw: String) -> String? {
        let s = TextNormalization.sanitizeValue(raw)
        guard !s.isEmpty else { return nil }
        switch kind {
        case .date:     return TextNormalization.firstMatch(dateRegex, in: TextNormalization.normalizeDigits(s))
        case .idNumber: return TextNormalization.firstMatch(idRegex, in: TextNormalization.normalizeDigits(s))
        case .number:   return TextNormalization.firstMatch(numberRegex, in: TextNormalization.normalizeDigits(s))
        case .postalCode:
            let compact = s.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            guard (3...12).contains(compact.count),
                  compact.rangeOfCharacter(from: .decimalDigits) != nil,
                  compact.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
            return s
        case .text:
            guard s.rangeOfCharacter(from: .letters) != nil else { return nil }
            return s
        }
    }
}
