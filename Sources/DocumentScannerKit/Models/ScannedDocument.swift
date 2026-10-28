//
//  ScannedDocument.swift
//  DocumentScannerKit
//
//  The single result type the SDK hands back. It is intentionally broad — a
//  normalized superset of the data any consumer-grade document scanner returns
//  today — yet stays simple to consume:
//
//      • `documentType` / `confidence`  — what was scanned, and how sure.
//      • `fields`                        — every extracted value, normalized.
//      • subscript + typed accessors     — pull a known value in one line.
//      • `mrz`                           — the full ICAO 9303 zone, if present.
//      • `rawText`                       — OCR lines, exactly as recognized.
//      • `jsonString`                    — the whole thing, serialized.
//

import Foundation

public struct ScannedDocument: Codable, Equatable, Sendable {

    /// What kind of document this was identified as.
    public var documentType: DocumentKind

    /// Confidence of the classification, 0...1.
    public var confidence: Double

    /// Human-readable reasons the document type was chosen (matched signals).
    public var classificationSignals: [String]

    /// Every extracted value, normalized, ordered, and de-duplicated.
    public var fields: [ScannedField]

    /// The parsed machine-readable zone, when the document has one.
    public var mrz: MRZResult?

    /// Recognized text lines, in reading order, exactly as OCR returned them.
    public var rawText: [String]

    /// When the scan was produced (set by the capture layer).
    public var scannedAt: Date?

    /// The type the caller declared in manual mode (`nil` in auto mode).
    public var expectedType: DocumentKind?

    /// JPEG of the scanned document — perspective-corrected and cropped to the
    /// document when a quad was found, else the full frame. Set by the image
    /// pipeline (camera / `parse(image:)`); nil for text-only parses. Kept out
    /// of `jsonData`/`jsonString` so the JSON stays readable.
    public var image: Data?

    private enum CodingKeys: String, CodingKey {
        case documentType, confidence, classificationSignals, fields, mrz,
             rawText, scannedAt, expectedType
    }

    /// The document face the scan shows (front/back), derived from the
    /// detected kind — e.g. an Emirates ID back or a passport photo page.
    public var documentSide: DocumentSide { documentType.side }

    /// `true` in auto mode, or in manual mode when the detected type matches
    /// what the caller declared. Lets callers reject a wrong-document capture.
    public var matchesExpectedType: Bool {
        guard let expectedType else { return true }
        return expectedType == documentType
    }

    public init(documentType: DocumentKind,
                confidence: Double = 0,
                classificationSignals: [String] = [],
                fields: [ScannedField] = [],
                mrz: MRZResult? = nil,
                rawText: [String] = [],
                scannedAt: Date? = nil,
                expectedType: DocumentKind? = nil) {
        self.documentType = documentType
        self.confidence = confidence
        self.classificationSignals = classificationSignals
        self.fields = fields
        self.mrz = mrz
        self.rawText = rawText
        self.scannedAt = scannedAt
        self.expectedType = expectedType
    }

    // MARK: - Lookups

    /// The value for a canonical key, or nil if it wasn't found.
    public subscript(_ key: ScannedFieldKey) -> String? {
        fields.first { $0.key == key }?.value
    }

    /// All fields in a category, preserving order.
    public func fields(in category: FieldCategory) -> [ScannedField] {
        fields.filter { $0.category == category }
    }

    /// A plain `[key: value]` dictionary of every field (last write wins).
    public var dictionary: [String: String] {
        Dictionary(fields.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { _, new in new })
    }

    // MARK: - Typed conveniences (most-requested fields)

    public var fullName: String? { self[.fullName] ?? composedName }
    public var surname: String? { self[.surname] }
    public var givenNames: String? { self[.givenNames] }
    public var dateOfBirth: String? { self[.dateOfBirth] }
    public var sex: String? { self[.sex] }
    public var nationality: String? { self[.nationality] }
    public var documentNumber: String? { self[.documentNumber] ?? self[.passportNumber] ?? self[.emiratesIDNumber] }
    public var dateOfExpiry: String? { self[.dateOfExpiry] }
    public var dateOfIssue: String? { self[.dateOfIssue] }

    // Cheque conveniences
    public var payeeName: String? { self[.payeeName] }
    public var bankName: String? { self[.bankName] }
    public var accountNumber: String? { self[.accountNumber] }
    public var chequeNumber: String? { self[.chequeNumber] }
    public var iban: String? { self[.iban] }
    public var amountInWords: String? { self[.amountInWords] }
    public var amountInFigures: String? { self[.amountInFigures] }

    private var composedName: String? {
        let parts = [self[.givenNames], self[.surname]].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Serialization

    public var jsonData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    public var jsonString: String {
        String(data: jsonData, encoding: .utf8) ?? "{}"
    }
}
