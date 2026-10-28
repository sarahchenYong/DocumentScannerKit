import XCTest
@testable import DocumentScannerKit

final class ChequeParserTests: XCTestCase {

    private let sampleCheque = [
        "Emirates NBD",
        "Date: 30/06/2026",
        "Pay  Gulf Trading Company LLC  or Order",
        "AED  Fifteen Thousand Two Hundred Fifty Dirhams Only",
        "AED  15,250.00",
        "Authorised Signatory",
        "000123  0260101  01234567890  29",
    ]

    func testClassifiedAsCheque() {
        let doc = DocumentParser.parse(recognizedLines: sampleCheque)
        XCTAssertEqual(doc.documentType, .bankCheque)
    }

    func testExtractsCoreFields() throws {
        let c = try XCTUnwrap(ChequeParser.parse(sampleCheque))
        XCTAssertEqual(c.bank, "Emirates NBD")
        XCTAssertEqual(c.payee, "Gulf Trading Company LLC")
        XCTAssertEqual(c.amountInFigures, "15,250.00")
        XCTAssertEqual(c.amountValue, Decimal(string: "15250.00"))
        XCTAssertEqual(c.currency, "AED")
        XCTAssertEqual(c.chequeNumber, "000123")
        XCTAssertEqual(c.accountNumber, "01234567890")
        XCTAssertTrue(c.amountInWords?.contains("Fifteen Thousand") == true)
    }

    func testIBANExtraction() throws {
        let c = try XCTUnwrap(ChequeParser.parse([
            "Mashreq", "Pay John Smith or bearer",
            "AED 500.00", "IBAN AE07 0331 2345 6789 0123 456",
            "001234 0100200 9988776655 31",
        ]))
        XCTAssertEqual(c.iban, "AE070331234567890123456")
        XCTAssertEqual(c.bank, "Mashreq")
    }

    func testUnifiedDocumentSurfacesChequeFields() {
        let doc = DocumentParser.parse(recognizedLines: sampleCheque)
        XCTAssertEqual(doc.payeeName, "Gulf Trading Company LLC")
        XCTAssertEqual(doc.amountInFigures, "15,250.00")
        XCTAssertEqual(doc.chequeNumber, "000123")
        XCTAssertEqual(doc.fields(in: .banking).isEmpty, false)
    }

    func testJSONRoundTrip() throws {
        let doc = DocumentParser.parse(recognizedLines: sampleCheque)
        let data = doc.jsonData
        let decoded = try JSONDecoder().decode(ScannedDocument.self, from: data)
        XCTAssertEqual(decoded.documentType, doc.documentType)
        XCTAssertEqual(decoded.chequeNumber, "000123")
        XCTAssertEqual(decoded.fields.count, doc.fields.count)
    }
}
