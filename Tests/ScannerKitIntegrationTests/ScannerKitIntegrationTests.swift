import XCTest
@testable import ScannerKitIntegration

final class ScannerKitIntegrationTests: XCTestCase {
    func testDefaultPolicyRejectsExpiredDocuments() {
        let input = ScannerKitPolicyInput(isExpired: true)

        let decision = ScannerKitPolicyEvaluator.evaluate(input)

        guard case .rejected(let reason) = decision else {
            return XCTFail("The default policy must reject expired documents.")
        }
        XCTAssertTrue(reason.contains("expired"))
    }

    func testPolicyCanAllowExpiredDocuments() {
        let input = ScannerKitPolicyInput(isExpired: true)
        let policy = ScannerKitDocumentPolicy(allowsExpiredDocuments: true)

        XCTAssertEqual(
            ScannerKitPolicyEvaluator.evaluate(input, using: policy),
            .accepted
        )
    }

    func testPolicyCanAllowUnexpectedDocumentType() {
        let input = ScannerKitPolicyInput(
            documentType: "nationalID",
            expectedDocumentType: "passport"
        )
        let policy = ScannerKitDocumentPolicy(allowsUnexpectedDocumentType: true)

        XCTAssertEqual(
            ScannerKitPolicyEvaluator.evaluate(input, using: policy),
            .accepted
        )
    }

    func testPolicySendsMissingFieldsToReview() {
        let input = ScannerKitPolicyInput(availableFields: ["name"])
        let policy = ScannerKitDocumentPolicy(requiredFields: ["name", "dateOfBirth"])

        guard case .review(let reason) = ScannerKitPolicyEvaluator.evaluate(input, using: policy) else {
            return XCTFail("Missing required fields should produce a review decision.")
        }
        XCTAssertTrue(reason.contains("dateOfBirth"))
    }

    func testResultMapperPreservesAppFacingValues() {
        let result = ScannerKitResultMapper.makeResult(
            documentType: "passport",
            fields: ["name": "Ada Lovelace"],
            isExpired: false
        )

        XCTAssertEqual(result.documentType, "passport")
        XCTAssertEqual(result.fields["name"], "Ada Lovelace")
        XCTAssertFalse(result.isExpired)
    }

    func testCaptureOptionsClampAttemptsToOne() {
        XCTAssertEqual(ScannerKitCaptureOptions(maximumCaptureAttempts: 0).maximumCaptureAttempts, 1)
    }
}
