//
//  AmountWords.swift
//  DocumentScannerKit
//
//  Renders a numeric amount as its English words. On a cheque the amount in
//  words is handwritten and OCRs poorly ("Sixteen Thousand" → "Speteen …
//  Hhaudand"), so rather than trust that text we regenerate the canonical
//  words from the validated figure — which is exact.
//

import Foundation

enum AmountWords {

    private static let ones = ["", "One", "Two", "Three", "Four", "Five", "Six",
                               "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve",
                               "Thirteen", "Fourteen", "Fifteen", "Sixteen",
                               "Seventeen", "Eighteen", "Nineteen"]
    private static let tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty",
                               "Sixty", "Seventy", "Eighty", "Ninety"]
    private static let scales = [(1_000_000_000, "Billion"), (1_000_000, "Million"), (1_000, "Thousand")]

    /// e.g. amount 16000, currency "AED" → "Sixteen Thousand Dirhams Only".
    /// Fractional fils are appended as "… and Fifty Fils".
    static func string(from amount: Decimal, currency: String?) -> String? {
        let whole = NSDecimalNumber(decimal: amount).intValue
        guard whole >= 0 else { return nil }
        let fils = Int((NSDecimalNumber(decimal: amount).doubleValue - Double(whole)) * 100 + 0.5)

        let majorName = (currency ?? "").uppercased() == "AED" ? "Dirhams" : (currency ?? "")
        var result = words(for: whole)
        if !majorName.isEmpty { result += " \(majorName)" }
        if fils > 0 {
            result += " and \(words(for: fils)) Fils"
        } else {
            result += " Only"
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Convert a non-negative integer to title-case English words.
    static func words(for n: Int) -> String {
        if n == 0 { return "Zero" }
        var n = n
        var parts: [String] = []
        for (value, name) in scales {
            if n >= value {
                parts.append(words(forUnderThousand: n / value) + " " + name)
                n %= value
            }
        }
        if n > 0 { parts.append(words(forUnderThousand: n)) }
        return parts.joined(separator: " ")
    }

    private static func words(forUnderThousand n: Int) -> String {
        var parts: [String] = []
        let hundreds = n / 100
        let rest = n % 100
        if hundreds > 0 { parts.append(ones[hundreds] + " Hundred") }
        if rest > 0 {
            if rest < 20 {
                parts.append(ones[rest])
            } else {
                let t = tens[rest / 10]
                parts.append(rest % 10 == 0 ? t : t + " " + ones[rest % 10])
            }
        }
        return parts.joined(separator: " ")
    }
}
