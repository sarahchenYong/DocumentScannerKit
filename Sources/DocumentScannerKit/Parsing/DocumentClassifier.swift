//
//  DocumentClassifier.swift
//  DocumentScannerKit
//
//  Decides *what* was scanned from the OCR lines (+ any MRZ already parsed),
//  via signal scoring: each kind accumulates points from keyword and format
//  matches; the highest scorer above a small threshold wins. The MRZ, when
//  present, is the strongest single signal.
//

import Foundation

public struct DocumentClassification: Sendable {
    public let kind: DocumentKind
    public let confidence: Double      // 0...1, winner's share of total score
    public let reasons: [String]
}

public enum DocumentClassifier {

    /// UAE Emirates ID number: 784-YYYY-NNNNNNN-C.
    static let emiratesIDRegex = try! NSRegularExpression(
        pattern: #"\b784[-\s]?\d{4}[-\s]?\d{7}[-\s]?\d\b"#)

    /// UAE permit file number: e.g. 201/2023/1234567.
    static let fileNumberRegex = try! NSRegularExpression(
        pattern: #"\b\d{2,3}\s?/\s?(?:19|20)\d{2}\s?/\s?\d{5,9}\b"#)

    /// UAE IBAN: AE + 2 check digits + 19 digits.
    static let uaeIBANRegex = try! NSRegularExpression(
        pattern: #"\bAE\d{2}[ ]?(?:\d[ ]?){19}\b"#, options: [.caseInsensitive])

    /// Banks operating in the UAE (plus a few international). Matched as whole
    /// words (see `matchedBankName`) so short names like "FAB"/"Liv"/"CBD" don't
    /// false-match inside ordinary words ("fabric", "delivery", …).
    public static let bankNames: [String] = [
        "Emirates NBD", "Emirates Islamic", "First Abu Dhabi", "FAB",
        "Abu Dhabi Commercial", "ADCB", "Abu Dhabi Islamic", "ADIB",
        "Dubai Islamic", "Mashreq", "RAKBANK", "RAK Bank",
        "National Bank of Fujairah", "Commercial Bank of Dubai", "CBD",
        "Sharjah Islamic", "United Arab Bank", "Ajman Bank", "Al Hilal",
        "Citibank", "HSBC", "Standard Chartered", "Barclays", "Wio",
        "Liv", "Bank of Baroda", "Habib Bank", "Doha Bank", "Noor Bank",
    ]

    /// Whole-word bank-name matcher (longest names first so "Emirates NBD" wins
    /// over "Emirates Islamic").
    private static let bankNameRegex: NSRegularExpression = {
        let names = bankNames.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(\(names))\\b", options: [.caseInsensitive])
    }()

    /// The canonical bank name present in `text` as a whole word, or nil.
    public static func matchedBankName(in text: String) -> String? {
        let r = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = bankNameRegex.firstMatch(in: text, range: r), let rng = Range(m.range, in: text) else { return nil }
        let found = String(text[rng])
        return bankNames.first { $0.caseInsensitiveCompare(found) == .orderedSame } ?? found
    }

    public static func classify(lines: [String], mrz: MRZResult?) -> DocumentClassification {
        let text = lines.joined(separator: "\n")
        let lower = text.lowercased()

        var scores: [DocumentKind: Double] = [:]
        var reasons: [DocumentKind: [String]] = [:]
        func add(_ kind: DocumentKind, _ points: Double, _ why: String) {
            scores[kind, default: 0] += points
            reasons[kind, default: []].append(why)
        }
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
        func matches(_ regex: NSRegularExpression) -> Bool {
            let r = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, range: r) != nil
        }

        // --- MRZ: most authoritative signal when present ---
        if let m = mrz {
            let country = m.issuingCountry.uppercased()
            let isUAE = country == "ARE" || country == "UAE"
            switch m.format {
            case .td3:
                // A checksum-valid TD3 MRZ is conclusive evidence of a
                // passport (or visa). UAE passports also print "United Arab
                // Emirates" and other ID-like labels, which must never
                // outweigh the MRZ and turn a Passport Front into an EID.
                if m.documentType.uppercased().hasPrefix("V") { add(.visa, 12, "TD3 MRZ, document type V") }
                else { add(.passportFront, 12, "TD3 passport MRZ") }
            case .td2:
                add(.visa, 4, "TD2 MRZ")
                if m.documentType.uppercased().hasPrefix("V") { add(.visa, 2, "document type V") }
            case .td1:
                if isUAE { add(.emiratesIDBack, 6, "TD1 MRZ, issuer ARE") }
                else     { add(.nationalID, 4, "TD1 MRZ (ID card)") }
            }
        }

        // Wording an identity card never carries but every UAE residence
        // permit / entry permit does. When present, permit-side signals own
        // the evidence that would otherwise suggest an Emirates ID.
        let permitContext = has("residence", "sponsor", "profession", "entry permit",
                                "u.i.d", "uid no", "file no", "file number", "إقامة")

        // --- Emirates ID ---
        if matches(emiratesIDRegex) {
            if permitContext { add(.visa, 5, "784 ID number on a permit layout") }
            else { add(.emiratesIDFront, 5, "ID number 784-…") }
        }
        if has("united arab emirates", "الإمارات العربية") { add(.emiratesIDFront, 2, "“United Arab Emirates”") }
        if has("resident identity card", "identity card", "id card", "هوية") { add(.emiratesIDFront, 3, "“Identity Card”") }
        if has("id number") { add(.emiratesIDFront, 2, "“ID Number” label") }
        if has("card number") { add(.emiratesIDBack, 2, "“Card Number” label") }
        if has("occupation")  { add(.emiratesIDBack, 2, "“Occupation” label") }
        if has("employer", "place of issue", "issuing place") { add(.emiratesIDBack, 1.5, "back-of-card label") }

        // --- Passport ---
        if has("passport") { add(.passportFront, 2, "“Passport” keyword") }
        if has("type", "country code") && has("passport") { add(.passportFront, 1, "passport field labels") }
        if has("passport") && mrz == nil
            && has("address", "holder", "spouse", "father", "mother", "endorsement") {
            add(.passportBack, 4, "passport page without MRZ (holder/address)")
        }
        // The address/family page often shows no "passport" wording at all —
        // but two or more of its family-name labels together are unique to it
        // (a PAN card carries only the father's name).
        let familyLabels = [has("father"), has("mother"), has("spouse"), has("legal guardian")]
            .filter { $0 }.count
        if mrz == nil, familyLabels >= 2 {
            add(.passportBack, 4, "passport back page (family-name labels)")
        }
        if mrz == nil, has("old passport") {
            add(.passportBack, 3, "old-passport reference")
        }

        // --- Visa / residence permit ---
        if has("visa") { add(.visa, 3, "“Visa” keyword") }
        if has("residence", "entry permit", "type of visa", "sponsor", "visa no",
               "permit no", "u.a.e residence") {
            add(.visa, 2, "visa-specific label")
        }
        // UAE entry permits / e-visas often never print the word "visa".
        if has("entry permit", "residence visa", "visit visa", "tourist visa",
               "golden visa", "تأشيرة", "إقامة") {
            add(.visa, 4, "entry-permit / visa-type wording")
        }
        // A UAE residence permit reads "RESIDENCE/إقامة" beside file /
        // profession / passport-number labels — wording an identity card
        // never carries (and which must outscore the 784-number cue).
        if has("residence", "اقامة"), has("file", "passport no", "profession", "sponsor") {
            add(.visa, 8, "residence-permit labels")
        }
        if has("sponsor"), has("file no", "file number", "u.i.d", "unified") {
            add(.visa, 2, "sponsor + file labels")
        }
        // Independent permit cues — several must fail together before a
        // permit can lose its classification to a missed OCR word.
        if has("u.i.d", "uid no", "unified no") { add(.visa, 3, "U.I.D. number label") }
        if has("profession") { add(.visa, 2, "“Profession” label") }   // an EID says "Occupation"
        if has("sponsor") { add(.visa, 2, "“Sponsor” label") }
        if matches(fileNumberRegex) { add(.visa, 3, "permit file number") }
        if has("residence permit", "permit to remain") { add(.residencePermit, 3, "“Residence Permit”") }

        // --- Driving licence ---
        if has("driving licence", "driving license", "driver licence", "driver license") {
            add(.drivingLicense, 4, "“Driving Licence”")
        }
        if has("dl no", "licence no", "license no", "vehicle", "class", "traffic") {
            add(.drivingLicense, 1.5, "licence field label")
        }

        // --- Trade / commercial licence ---
        if has("trade license", "trade licence", "commercial license", "commercial licence",
               "professional license", "professional licence", "رخصة تجارية") {
            add(.tradeLicense, 6, "“Trade License” heading")
        }
        if has("trade name", "الاسم التجاري") { add(.tradeLicense, 3, "“Trade Name” label") }
        if has("legal type", "legal form", "legal status") { add(.tradeLicense, 2, "legal-type label") }
        if has("economic dep", "department of economic", "economy and tourism", "economic development") {
            add(.tradeLicense, 2, "economic-department wording")
        }
        if has("license activity", "licence activity", "business activity", "activities") {
            add(.tradeLicense, 1.5, "activity label")
        }
        if has("commercial register", "registration no", "register no") {
            add(.tradeLicense, 1.5, "commercial-register label")
        }
        if has("duns") { add(.tradeLicense, 1.5, "DUNS label") }

        // --- Address-bearing documents ---
        // These signals deliberately require a document-specific heading, so a
        // postal address printed on an ID or passport still classifies as that
        // identity document rather than as a bill.
        if has("dewa", "dubai electricity and water authority") { add(.utilityBill, 6, "DEWA heading") }
        if has("electricity bill", "water bill", "utility bill", "tax invoice") {
            add(.utilityBill, 4, "utility-bill heading")
        }
        if has("account number", "premise number", "premise no", "customer account"),
           has("bill", "electricity", "water", "consumption", "amount due") {
            add(.utilityBill, 3, "utility account and billing labels")
        }
        if has("business card") { add(.businessCard, 5, "business-card heading") }
        if has("tel", "telephone", "mobile", "e-mail", "email", "www."),
           has("office", "llc", "l.l.c", "manager", "director", "consultant") {
            add(.businessCard, 4, "business contact details")
        }

        // A plain page is only classified as an address note if it says so.
        // This is useful for handwritten notes, while avoiding speculation
        // about generic prose that merely happens to mention a place.
        if has("address", "deliver to", "shipping address", "mailing address"), mrz == nil,
           !has("passport", "identity card", "resident identity") {
            add(.addressNote, 3, "address-note label")
        }

        // --- Bank cheque (strict) ---
        // A cheque is only claimed with a STRONG, cheque-specific signal, so a
        // stray "pay"/"only" or a bank word on another document can't make e.g.
        // a passport back look like a cheque. Weak signals only add weight once a
        // strong one is present.
        let bankName = DocumentClassifier.matchedBankName(in: text)
        var strong = 0.0, weak = 0.0
        var chequeWhy: [String] = []
        if has("or order", "or bearer", "to the order of") { strong += 3; chequeWhy.append("“or order/bearer”") }
        if let micr = ChequeParser.micrLine(in: lines) { strong += 3; chequeWhy.append("MICR line: \(micr.prefix(16))…") }
        if matches(uaeIBANRegex) { strong += 2; chequeWhy.append("IBAN present") }
        if has("a/c payee", "account payee") { strong += 2; chequeWhy.append("A/C payee marking") }
        if bankName != nil { weak += 1.5; chequeWhy.append("bank name") }
        if has("dirhams", "aed", "fils", "dhs") { weak += 1; chequeWhy.append("currency") }
        if has("cheque", "check") { weak += 1; chequeWhy.append("cheque keyword") }
        if has("pay") { weak += 0.5 }
        if has("valid for", "only", "the sum of") { weak += 0.5 }
        // Qualify on a strong signal, or an unambiguous bank + currency + pay combo.
        let chequeQualifies = strong > 0
            || (bankName != nil && has("dirhams", "aed", "dhs") && has("pay", "cheque"))
        if chequeQualifies { add(.bankCheque, strong + weak, chequeWhy.joined(separator: ", ")) }

        // --- Decide ---
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 3 else {
            return DocumentClassification(kind: .unknown, confidence: 0, reasons: [])
        }
        // Confidence is absolute, not a share of the total: it combines how much
        // evidence the winner gathered (magnitude, saturating around a score of
        // 10) with how clearly it beat the runner-up (margin). This way a single
        // weak signal no longer reads as 100%.
        let sortedScores = scores.values.sorted(by: >)
        let bestVal = sortedScores[0]
        let secondVal = sortedScores.count > 1 ? sortedScores[1] : 0
        let magnitude = min(1.0, bestVal / 10.0)
        let margin = (bestVal + secondVal) > 0 ? bestVal / (bestVal + secondVal) : 1
        let confidence = magnitude * (0.5 + 0.5 * margin)
        return DocumentClassification(kind: best.key, confidence: confidence, reasons: reasons[best.key] ?? [])
    }
}
