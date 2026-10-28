import Foundation

public enum ScannerKitReviewReason: String, Sendable {
    case missingRequiredField
    case lowConfidence
    case expiredDocument
    case unexpectedDocumentType
    case mrzValidationFailure
}

public struct ScannerKitReviewPolicy: Sendable {
    public var sendsLowConfidenceResultsToReview: Bool
    public var sendsPolicyFailuresToReview: Bool

    public init(
        sendsLowConfidenceResultsToReview: Bool = true,
        sendsPolicyFailuresToReview: Bool = false
    ) {
        self.sendsLowConfidenceResultsToReview = sendsLowConfidenceResultsToReview
        self.sendsPolicyFailuresToReview = sendsPolicyFailuresToReview
    }
}
