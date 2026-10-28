import Foundation

public struct ScannerKitMappedResult: Sendable {
    public let documentType: String?
    public let fields: [String: String]
    public let isExpired: Bool

    public init(documentType: String?, fields: [String: String], isExpired: Bool) {
        self.documentType = documentType
        self.fields = fields
        self.isExpired = isExpired
    }
}

public enum ScannerKitResultMapper {
    public static func makeResult(
        documentType: String?,
        fields: [String: String],
        isExpired: Bool
    ) -> ScannerKitMappedResult {
        ScannerKitMappedResult(documentType: documentType, fields: fields, isExpired: isExpired)
    }
}
