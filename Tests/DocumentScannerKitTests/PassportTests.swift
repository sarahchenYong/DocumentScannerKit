import XCTest
@testable import DocumentScannerKit

final class PassportTests: XCTestCase {

    // MARK: - Passport front: issue date & place come from the printed zone

    func testPassportFrontExtractsIssueDateAndPlace() {
        let line1 = "P<UTOERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 19)
        let line2 = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
        let doc = DocumentParser.parse(recognizedLines: [
            line1, line2,
            "Passport No L898902C3",
            "Date of Issue 15/03/2018",
            "Place of Issue DUBAI",
            "Authority DUBAI",
        ], expecting: .passportFront)

        XCTAssertEqual(doc.documentType, .passportFront)
        XCTAssertEqual(doc[.dateOfIssue], "15/03/2018")
        XCTAssertEqual(doc[.placeOfIssue], "DUBAI")
        XCTAssertNotNil(doc.mrz)
    }

    // MARK: - Passport back must NOT be mistaken for a cheque

    private let passportBack = [
        "Address: 12 Main Street, Dubai",
        "Father's Name: John Doe",
        "Mother's Name: Mary Doe",
        "Spouse: Jane Doe",
        "Place of Issue: DUBAI",
        "Old Passport No: A1234567",
    ]

    func testPassportBackNotClassifiedAsCheque() {
        let doc = DocumentParser.parse(recognizedLines: passportBack)
        XCTAssertNotEqual(doc.documentType, .bankCheque)
    }

    func testManualPassportBackTrustsChoiceAndExtracts() {
        let doc = DocumentParser.parse(recognizedLines: passportBack, expecting: .passportBack)
        XCTAssertEqual(doc.documentType, .passportBack)   // trusts the chosen type
        XCTAssertTrue(doc.matchesExpectedType)
        XCTAssertEqual(doc[.address]?.contains("Main Street"), true)
        XCTAssertEqual(doc[.fathersName], "John Doe")
        XCTAssertEqual(doc[.spouseName], "Jane Doe")
    }

    // MARK: - Bank names match as whole words only

    func testBankNameWordBoundary() {
        XCTAssertNil(DocumentClassifier.matchedBankName(in: "fast delivery and fabric store"))   // Liv / FAB
        XCTAssertNil(DocumentClassifier.matchedBankName(in: "the cbdc pilot and wios"))
        XCTAssertEqual(DocumentClassifier.matchedBankName(in: "Drawn on Emirates NBD"), "Emirates NBD")
        XCTAssertEqual(DocumentClassifier.matchedBankName(in: "pay via FAB today"), "FAB")
    }

    // A page with a stray bank word + "pay" but no real cheque signal isn't a cheque.
    func testWeakSignalsAreNotACheque() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Please pay attention to the delivery",
            "Only valid identification accepted",
        ])
        XCTAssertNotEqual(doc.documentType, .bankCheque)
    }
}
