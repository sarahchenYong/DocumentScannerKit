import Foundation

public enum ScannerKitAcceptance: Sendable, Equatable {
    case accepted
    case review(reason: String)
    case rejected(reason: String)
}

/// A small, app-owned policy evaluator. The scanner binary remains responsible
/// for producing and validating the underlying document data.
public struct ScannerKitPolicyInput: Sendable {
    public var documentType: String?
    public var expectedDocumentType: String?
    public var isExpired: Bool
    public var mrzCheckPassed: Bool?
    public var availableFields: Set<String>

    public init(
        documentType: String? = nil,
        expectedDocumentType: String? = nil,
        isExpired: Bool = false,
        mrzCheckPassed: Bool? = nil,
        availableFields: Set<String> = []
    ) {
        self.documentType = documentType
        self.expectedDocumentType = expectedDocumentType
        self.isExpired = isExpired
        self.mrzCheckPassed = mrzCheckPassed
        self.availableFields = availableFields
    }
}

public enum ScannerKitPolicyEvaluator {
    public static func evaluate(
        _ input: ScannerKitPolicyInput,
        using policy: ScannerKitDocumentPolicy = .default
    ) -> ScannerKitAcceptance {
        if input.isExpired && !policy.allowsExpiredDocuments {
            return .rejected(reason: "The document is expired.")
        }
        if let expected = input.expectedDocumentType,
           let actual = input.documentType,
           expected != actual,
           !policy.allowsUnexpectedDocumentType {
            return .rejected(reason: "The document type is not allowed for this flow.")
        }
        if input.mrzCheckPassed == false && !policy.allowsMRZCheckFailure {
            return .rejected(reason: "The MRZ validation did not pass.")
        }
        let missingFields = policy.requiredFields.subtracting(input.availableFields)
        if !missingFields.isEmpty {
            return .review(reason: "Required fields are missing: \(missingFields.sorted().joined(separator: ", ")).")
        }
        return .accepted
    }
}
