//
//  MRZParser.swift
//  DocumentScannerKit
//
//  Self-contained ICAO 9303 machine-readable-zone parser with check-digit
//  validation. Supports TD1 (ID card / Emirates ID, 3×30), TD2 (2×36), and
//  TD3 (passport, 2×44).
//

import Foundation

// MARK: - Result model

public struct MRZResult: Equatable, Codable, Sendable {
    public enum Format: String, Codable, Sendable { case td1, td2, td3 }

    public var format: Format
    public var documentType: String
    public var issuingCountry: String
    public var surname: String
    public var givenNames: String
    public var documentNumber: String
    public var nationality: String
    public var dateOfBirth: String      // raw YYMMDD
    public var sex: String
    public var expiryDate: String       // raw YYMMDD
    public var optionalData: String
    public var allChecksPassed: Bool
}

// MARK: - Parser (ICAO 9303)

public enum MRZParser {

    /// Character -> numeric value used by the check-digit algorithm.
    private static func value(_ c: Character) -> Int {
        if c == "<" { return 0 }
        if let d = c.wholeNumberValue, c.isNumber { return d }
        let scalars = c.unicodeScalars
        guard let s = scalars.first, scalars.count == 1 else { return 0 }
        return Int(s.value) - Int(Character("A").unicodeScalars.first!.value) + 10
    }

    /// ICAO weighted check digit (weights cycle 7, 3, 1).
    public static func checkDigit(_ field: String) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, c) in field.enumerated() { sum += value(c) * weights[i % 3] }
        return sum % 10
    }

    private static func passes(_ field: String, _ check: Character) -> Bool {
        guard let cd = check.wholeNumberValue else { return false }
        return checkDigit(field) == cd
    }

    private static func sub(_ s: [Character], _ r: Range<Int>) -> String {
        guard r.lowerBound >= 0, r.upperBound <= s.count else { return "" }
        return String(s[r])
    }

    private static func clean(_ s: String) -> String {
        s.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<".contains($0) }
    }

    private static func names(from field: String) -> (surname: String, given: String) {
        let parts = field.components(separatedBy: "<<")
        let surname = parts.first?.replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
        let given = (parts.count > 1 ? parts[1] : "")
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (surname, given)
    }

    /// Parse an assembled MRZ block (lines joined by "\n"). Returns nil if it
    /// doesn't match a known format or the core check digits fail.
    ///
    /// General-purpose OCR confuses look-alike characters in the OCR-B strip
    /// (O↔0, I↔1, S↔5, B↔8 …), which breaks the check digits. Each format is
    /// therefore tried in up to three passes: the raw text; a repaired variant
    /// that forces digit zones (dates, check digits) to digits and alphabetic
    /// zones (country codes) to letters; and an aggressive variant that also
    /// digit-maps the alphanumeric zones (document number, optional data) —
    /// the check digits arbitrate, so a false repair cannot pass silently.
    public static func parse(_ block: String) -> MRZResult? {
        let lines = block.split(separator: "\n").map { clean(String($0)) }
        for level in 0...2 {
            let result: MRZResult?
            switch lines.count {
            case 2 where lines.allSatisfy({ $0.count == 44 }):
                result = parseTD3(repaired(lines, format: .td3, level: level))
            case 2 where lines.allSatisfy({ $0.count == 36 }):
                result = parseTD2(repaired(lines, format: .td2, level: level))
            case 3 where lines.allSatisfy({ $0.count == 30 }):
                result = parseTD1(repaired(lines, format: .td1, level: level))
            default:
                return nil
            }
            if let result { return result }
        }
        return nil
    }

    // MARK: - OCR look-alike repair

    private enum Zone { case digits, alpha, alnum }

    private static let digitFixes: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "U": "0", "I": "1", "L": "1",
        "Z": "2", "S": "5", "B": "8", "G": "6",
    ]
    private static let letterFixes: [Character: Character] = [
        "0": "O", "1": "I", "2": "Z", "5": "S", "8": "B", "6": "G",
    ]

    /// Positional zone layout per format: (line, range, kind).
    private static func zones(for format: MRZResult.Format) -> [(line: Int, range: Range<Int>, kind: Zone)] {
        switch format {
        case .td3:
            return [(0, 2..<5, .alpha),                     // issuing country
                    (1, 0..<9, .alnum), (1, 9..<10, .digits),   // doc number + cd
                    (1, 10..<13, .alpha),                   // nationality
                    (1, 13..<20, .digits),                  // birth + cd
                    (1, 21..<28, .digits),                  // expiry + cd
                    (1, 28..<42, .alnum), (1, 42..<44, .digits)] // personal + cds
        case .td2:
            return [(0, 2..<5, .alpha),
                    (1, 0..<9, .alnum), (1, 9..<10, .digits),
                    (1, 10..<13, .alpha),
                    (1, 13..<20, .digits),
                    (1, 21..<28, .digits),
                    (1, 28..<35, .alnum), (1, 35..<36, .digits)]
        case .td1:
            return [(0, 2..<5, .alpha),
                    (0, 5..<14, .alnum), (0, 14..<15, .digits),  // doc number + cd
                    (0, 15..<30, .alnum),                        // optional 1
                    (1, 0..<7, .digits),                         // birth + cd
                    (1, 8..<15, .digits),                        // expiry + cd
                    (1, 15..<18, .alpha),                        // nationality
                    (1, 18..<29, .alnum), (1, 29..<30, .digits)] // optional 2 + cd
        }
    }

    /// Level 0: untouched. Level 1: force digit/alpha zones. Level 2: also
    /// digit-map the alphanumeric zones (document numbers and the Emirates
    /// ID's numeric optional data are digit-heavy in practice).
    private static func repaired(_ lines: [String], format: MRZResult.Format, level: Int) -> [String] {
        guard level > 0 else { return lines }
        var chars = lines.map { Array($0) }
        for zone in zones(for: format) {
            guard zone.line < chars.count,
                  zone.range.upperBound <= chars[zone.line].count else { continue }
            for i in zone.range {
                let c = chars[zone.line][i]
                guard c != "<" else { continue }
                switch zone.kind {
                case .digits: chars[zone.line][i] = digitFixes[c] ?? c
                case .alpha:  chars[zone.line][i] = letterFixes[c] ?? c
                case .alnum:  if level >= 2 { chars[zone.line][i] = digitFixes[c] ?? c }
                }
            }
        }
        return chars.map { String($0) }
    }

    // TD3 — passport, 2 lines x 44
    private static func parseTD3(_ lines: [String]) -> MRZResult? {
        let l1 = Array(lines[0]), l2 = Array(lines[1])

        let docNum   = sub(l2, 0..<9)
        let docNumCD = l2[9]
        let birth    = sub(l2, 13..<19)
        let birthCD  = l2[19]
        let expiry   = sub(l2, 21..<27)
        let expiryCD = l2[27]
        let personal = sub(l2, 28..<42)
        let personalCD = l2[42]
        let compositeCD = l2[43]

        let composite = sub(l2, 0..<10) + sub(l2, 13..<20) + sub(l2, 21..<43)

        let core = passes(docNum, docNumCD) && passes(birth, birthCD) && passes(expiry, expiryCD)
        let all = core && passes(personal, personalCD) && passes(composite, compositeCD)
        guard core else { return nil }

        let (sur, giv) = names(from: sub(l1, 5..<44))
        return MRZResult(
            format: .td3,
            documentType: sub(l1, 0..<2).replacingOccurrences(of: "<", with: ""),
            issuingCountry: sub(l1, 2..<5),
            surname: sur, givenNames: giv,
            documentNumber: docNum.replacingOccurrences(of: "<", with: ""),
            nationality: sub(l2, 10..<13),
            dateOfBirth: birth, sex: String(l2[20]),
            expiryDate: expiry,
            optionalData: personal.replacingOccurrences(of: "<", with: ""),
            allChecksPassed: all
        )
    }

    // TD2 — 2 lines x 36
    private static func parseTD2(_ lines: [String]) -> MRZResult? {
        let l1 = Array(lines[0]), l2 = Array(lines[1])

        let docNum   = sub(l2, 0..<9)
        let docNumCD = l2[9]
        let birth    = sub(l2, 13..<19)
        let birthCD  = l2[19]
        let expiry   = sub(l2, 21..<27)
        let expiryCD = l2[27]
        let compositeCD = l2[35]
        let composite = sub(l2, 0..<10) + sub(l2, 13..<20) + sub(l2, 21..<35)

        let core = passes(docNum, docNumCD) && passes(birth, birthCD) && passes(expiry, expiryCD)
        let all = core && passes(composite, compositeCD)
        guard core else { return nil }

        let (sur, giv) = names(from: sub(l1, 5..<36))
        return MRZResult(
            format: .td2,
            documentType: sub(l1, 0..<2).replacingOccurrences(of: "<", with: ""),
            issuingCountry: sub(l1, 2..<5),
            surname: sur, givenNames: giv,
            documentNumber: docNum.replacingOccurrences(of: "<", with: ""),
            nationality: sub(l2, 10..<13),
            dateOfBirth: birth, sex: String(l2[20]),
            expiryDate: expiry,
            optionalData: sub(l2, 28..<35).replacingOccurrences(of: "<", with: ""),
            allChecksPassed: all
        )
    }

    // TD1 — ID card / Emirates ID, 3 lines x 30
    private static func parseTD1(_ lines: [String]) -> MRZResult? {
        let l1 = Array(lines[0]), l2 = Array(lines[1]), l3 = Array(lines[2])

        let docNum   = sub(l1, 5..<14)
        let docNumCD = l1[14]
        let birth    = sub(l2, 0..<6)
        let birthCD  = l2[6]
        let expiry   = sub(l2, 8..<14)
        let expiryCD = l2[14]
        let compositeCD = l2[29]
        let composite = sub(l1, 5..<30) + sub(l2, 0..<7) + sub(l2, 8..<15) + sub(l2, 18..<29)

        let core = passes(docNum, docNumCD) && passes(birth, birthCD) && passes(expiry, expiryCD)
        let all = core && passes(composite, compositeCD)
        guard core else { return nil }

        let (sur, giv) = names(from: String(l3))
        return MRZResult(
            format: .td1,
            documentType: sub(l1, 0..<2).replacingOccurrences(of: "<", with: ""),
            issuingCountry: sub(l1, 2..<5),
            surname: sur, givenNames: giv,
            documentNumber: docNum.replacingOccurrences(of: "<", with: ""),
            nationality: sub(l2, 15..<18),
            dateOfBirth: birth, sex: String(l2[7]),
            expiryDate: expiry,
            optionalData: (sub(l1, 15..<30) + sub(l2, 18..<29)).replacingOccurrences(of: "<", with: ""),
            allChecksPassed: all
        )
    }

    // MARK: - MRZ assembly from loose OCR lines

    /// Build candidate MRZ blocks from recognized lines (top-to-bottom). OCR
    /// rarely returns exact line widths, so each line is normalized toward a
    /// target width (right-padding with "<", trimming a stray trailing char);
    /// the check digits then accept or reject.
    public static func candidateBlocks(_ lines: [String]) -> [String] {
        // An MRZ line reaches OCR as one unbroken run of A-Z / 0-9 / '<'.
        // Judge each raw line by that shape — ≥90% MRZ characters once spaces
        // are dropped, carrying at least one digit or filler — rather than
        // demanding a '<', which a fully-populated line doesn't have (an
        // Emirates ID's TD1 first line fills its whole optional area with the
        // 784… ID number). Lowercase letters mark prose, not MRZ.
        func mrzish(_ raw: String) -> String? {
            let compact = raw.filter { !$0.isWhitespace }
            guard compact.count >= 25 else { return nil }
            let kept = compact.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<".contains($0) }
            guard Double(kept.count) >= 0.9 * Double(compact.count),
                  kept.contains(where: { $0.isNumber || $0 == "<" }) else { return nil }
            return kept
        }

        func normalize(_ s: String, to width: Int) -> String? {
            if s.count == width { return s }
            if s.count < width, width - s.count <= 4 { return s + String(repeating: "<", count: width - s.count) }
            if s.count > width, s.count - width <= 2 { return String(s.prefix(width)) }
            return nil
        }

        // Every window of consecutive candidates is a block — the check
        // digits decide which is real. ("Take the last N" broke on dual-pass
        // OCR, whose duplicate line sets straddle the cut.)
        let candidates = lines.compactMap(mrzish)
        var blocks: [String] = []
        for width in [44, 36] {
            let m = candidates.compactMap { normalize($0, to: width) }
            for i in m.indices.dropLast() { blocks.append(m[i] + "\n" + m[i + 1]) }
        }
        let td1 = candidates.compactMap { normalize($0, to: 30) }
        for i in td1.indices.dropLast(2) { blocks.append(td1[i...(i + 2)].joined(separator: "\n")) }
        return blocks
    }

    /// Convenience: find the first valid MRZ among loose OCR lines.
    public static func firstValid(in lines: [String]) -> MRZResult? {
        for block in candidateBlocks(lines) {
            if let r = parse(block) { return r }
        }
        return nil
    }
}
