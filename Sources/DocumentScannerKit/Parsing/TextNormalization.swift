//
//  TextNormalization.swift
//  DocumentScannerKit
//
//  Shared text utilities used across the parsers: digit normalization for
//  Arabic-Indic numerals, Arabic-script stripping (so the English half of a
//  bilingual UAE card survives), value sanitization, and date detection.
//

import Foundation

public enum TextNormalization {

    /// Map Arabic-Indic (٠-٩) and Eastern Arabic-Indic (۰-۹) digits to ASCII.
    public static func normalizeDigits(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0660...0x0669: out.append(UnicodeScalar(u.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: out.append(UnicodeScalar(u.value - 0x06F0 + 0x30)!)
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Remove Arabic-script characters across all Unicode Arabic blocks.
    public static func stripArabic(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { u in
            !(0x0600...0x06FF).contains(u.value)   // Arabic
                && !(0x0750...0x077F).contains(u.value)   // Arabic Supplement
                && !(0x08A0...0x08FF).contains(u.value)   // Arabic Extended-A
                && !(0xFB50...0xFDFF).contains(u.value)   // Presentation Forms-A
                && !(0xFE70...0xFEFF).contains(u.value)   // Presentation Forms-B
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Clean a field value: ASCII-ize digits, drop Arabic script, trim separators.
    public static func sanitizeValue(_ raw: String) -> String {
        let digits = normalizeDigits(raw)
        let latin = stripArabic(digits)
        return latin
            .trimmingCharacters(in: CharacterSet(charactersIn: " :;-_.#=|/\\").union(.whitespacesAndNewlines))
    }

    /// Dates the system data detector finds anywhere in `text`, medium-formatted.
    public static func detectDates(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let f = DateFormatter(); f.dateStyle = .medium
        var seen = Set<String>(), out: [String] = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let d = match?.date else { return }
            let s = f.string(from: d)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    static func firstMatch(_ regex: NSRegularExpression, in s: String) -> String? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = regex.firstMatch(in: s, range: range), let r = Range(m.range, in: s)
        else { return nil }
        return String(s[r])
    }
}
