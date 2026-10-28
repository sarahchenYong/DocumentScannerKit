import XCTest
@testable import DocumentScannerKit

/// Regression test from the *actual* dual-pass OCR of a real Emirates ID back.
/// Its TD1 first line is fully populated (no '<' at all — the optional area
/// carries the whole 784… ID number), which the old MRZ line filter rejected,
/// so the checksummed MRZ was ignored and only weak OCR labels survived.
final class EmiratesIDBackScanTests: XCTestCase {

    // Verbatim Vision output (two OCR passes → duplicated lines).
    private let lines = [
        "148565893",
        "dseyll wasigali",
        "Occupation: Software Engineer",
        "UAE",
        "Employer: Mag 5 Dwc-Llc",
        "Issuing Place: Dubai",
        "If you find this card, please return ittotheissuine-aa",
        "2504421861",
        "organization or to the nearest police station.",
        "ILARE1485658931784199159658436",
        "9107061M2709031IND<<<<<<<<<<<1",
        "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
        "Card Number/dölbul pö",
        "148565893",
        "Occupation: Software Engineer",
        "2200→sA $=5c-:jalah",
        "Employer: Mag 5 Dwc-Llc",
        "Issuing Place: Dubai",
        "If you find this card, please return i tothe issuintead",
        "2504421861",
        "organization or to the nearest pollice station.",
        "ILARE1485658931784199159658436",
        "9107061M2709031IND<<<<<<<<<<<1",
        "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
    ]

    func testMRZIsParsedDespiteFillerFreeFirstLine() throws {
        let mrz = try XCTUnwrap(MRZParser.firstValid(in: lines))
        XCTAssertEqual(mrz.format, .td1)
        XCTAssertEqual(mrz.documentType, "IL")
        XCTAssertEqual(mrz.issuingCountry, "ARE")
        XCTAssertEqual(mrz.documentNumber, "148565893")
        XCTAssertEqual(mrz.surname, "DEVANGAM YERRA")
        XCTAssertEqual(mrz.givenNames, "SAMPLE USER")
        XCTAssertEqual(mrz.nationality, "IND")
        XCTAssertEqual(mrz.dateOfBirth, "910706")
        XCTAssertEqual(mrz.sex, "M")
        XCTAssertEqual(mrz.expiryDate, "270903")
        XCTAssertTrue(mrz.allChecksPassed)
    }

    func testMRZValuesWinOverOCR() {
        let doc = DocumentParser.parse(recognizedLines: lines)

        XCTAssertEqual(doc.documentType, .emiratesIDBack)
        XCTAssertEqual(doc.documentType.rawValue, "ID — Back")

        // MRZ-derived values, all at checksummed confidence.
        XCTAssertEqual(doc[.surname], "DEVANGAM YERRA")
        XCTAssertEqual(doc[.givenNames], "SAMPLE USER")
        XCTAssertEqual(doc[.documentNumber], "148565893")
        XCTAssertEqual(doc[.nationalityCode], "IND")
        XCTAssertEqual(doc[.dateOfBirth], "06 Jul 1991")
        XCTAssertEqual(doc[.sex], "M")
        XCTAssertEqual(doc[.dateOfExpiry], "03 Sep 2027")
        XCTAssertEqual(doc[.emiratesIDNumber], "784-1991-5965843-6")

        // OCR may only fill what the MRZ can't answer.
        XCTAssertEqual(doc[.occupation], "Software Engineer")
        XCTAssertNil(doc[.fullName])       // MRZ owns the name
        XCTAssertNil(doc[.cardNumber])     // MRZ owns the document number

        // MRZ fields carry the checksummed confidence.
        let surname = doc.fields.first { $0.key == .surname }
        XCTAssertEqual(surname?.confidence, 0.98)
    }
}
