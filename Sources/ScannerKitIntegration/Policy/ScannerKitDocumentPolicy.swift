import Foundation

/// App-level acceptance rules applied after the protected scanner returns a
/// structured result. These settings never alter scanning, OCR, parsing, or
/// license enforcement inside the binary SDK.
public struct ScannerKitDocumentPolicy: Sendable {
    public var allowsExpiredDocuments: Bool
    public var allowsUnexpectedDocumentType: Bool
    public var allowsMRZCheckFailure: Bool
    public var requiredFields: Set<String>

    public init(
        allowsExpiredDocuments: Bool = false,
        allowsUnexpectedDocumentType: Bool = false,
        allowsMRZCheckFailure: Bool = false,
        requiredFields: Set<String> = []
    ) {
        self.allowsExpiredDocuments = allowsExpiredDocuments
        self.allowsUnexpectedDocumentType = allowsUnexpectedDocumentType
        self.allowsMRZCheckFailure = allowsMRZCheckFailure
        self.requiredFields = requiredFields
    }

    public static let `default` = ScannerKitDocumentPolicy()
}
