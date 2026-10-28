import XCTest
@testable import DocumentScannerKit

final class IBANExtractionTests: XCTestCase {

    // MARK: - Labelled and bare readings

    func testLabelledUAEIBANOnItsOwnLine() {
        let iban = IBANExtractor.extract(from: ["IBAN: AE07 0331 2345 6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
        XCTAssertEqual(iban?.confidence, 0.95)
    }

    func testBareUAEIBANWithoutAnyLabel() {
        let iban = IBANExtractor.extract(from: ["AE460090000000123456789"])
        XCTAssertEqual(iban?.value, "AE460090000000123456789")
        XCTAssertEqual(iban?.confidence, 0.95)
    }

    func testLabelledValueOnTheNextLine() {
        let iban = IBANExtractor.extract(from: ["IBAN Number", "AE07 0331 2345 6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
    }

    func testIBANWrappedAcrossTwoOCRLines() {
        let iban = IBANExtractor.extract(from: ["IBAN: AE07 0331 2345", "6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
    }

    func testLowercaseHandwritingStyleReading() {
        let iban = IBANExtractor.extract(from: ["iban ae07 0331 2345 6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
    }

    // MARK: - Any-country support

    func testInternationalIBANsValidate() {
        let samples = [
            "GB29 NWBK 6016 1331 9268 19": "GB29NWBK60161331926819",
            "DE89 3704 0044 0532 0130 00": "DE89370400440532013000",
            "SA03 8000 0000 6080 1016 7519": "SA0380000000608010167519",
            "QA58 DOHB 0000 1234 5678 90AB CDEF G": "QA58DOHB00001234567890ABCDEFG",
            "FR14 2004 1010 0505 0001 3M02 606": "FR1420041010050500013M02606",
            "TR33 0006 1005 1978 6457 8413 26": "TR330006100519786457841326",
            "PK36 SCBL 0000 0011 2345 6702": "PK36SCBL0000001123456702",
            "KW81 CBKU 0000 0000 0000 1234 5601 01": "KW81CBKU0000000000001234560101",
        ]
        for (printed, expected) in samples {
            let iban = IBANExtractor.extract(from: ["IBAN: \(printed)"])
            XCTAssertEqual(iban?.value, expected, "for \(printed)")
            XCTAssertEqual(iban?.confidence, 0.95, "for \(printed)")
        }
    }

    // MARK: - Handwriting / OCR confusions

    func testRepairsLetterForDigitConfusions() {
        // O read for 0, I for 1, S for 5 — the checksum proves the repair.
        let iban = IBANExtractor.extract(from: ["IBAN AEO7 O331 234S 6789 0I23 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
        XCTAssertEqual(iban?.confidence, 0.9)
    }

    func testKeepsExactLengthShapeWhenChecksumCannotBeProven() {
        // A misread real digit (7→9) can't be repaired by letter mapping —
        // the exact-length shape survives at low confidence so the user can
        // correct it, rather than getting nothing.
        let iban = IBANExtractor.extract(from: ["IBAN: AE09 0331 2345 6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE090331234567890123456")
        XCTAssertEqual(iban?.confidence, 0.6)
    }

    func testPrefersChecksumValidCandidateOverShapeOnly() {
        let iban = IBANExtractor.extract(from: [
            "Old account AE09 0331 2345 6789 0123 456",
            "IBAN: AE46 0090 0000 0012 3456 789",
        ])
        XCTAssertEqual(iban?.value, "AE460090000000123456789")
        XCTAssertEqual(iban?.confidence, 0.95)
    }

    // MARK: - Rejections

    func testOrdinaryTextIsNeverAnIBAN() {
        XCTAssertNil(IBANExtractor.extract(from: [
            "Address: Villa 17, Al Noor Street", "Dubai, United Arab Emirates",
            "Account statement for March 2026", "Total AED 12,345.67",
        ]))
    }

    func testUnknownCountryPrefixIsRejected() {
        XCTAssertNil(IBANExtractor.extract(from: ["ZZ07 0331 2345 6789 0123 456"]))
    }

    func testTruncatedIBANIsRejected() {
        XCTAssertNil(IBANExtractor.extract(from: ["IBAN: AE07 0331 2345"]))
    }

    func testUnprovenShapeSpanningTwoUnrelatedLinesIsRejected() {
        // "…No 1234567" + "Total due…" is a 15-character NO-prefixed run once
        // the lines are joined for the wrap search. Only a checksum may prove
        // a joined candidate, so this one is not an IBAN.
        XCTAssertNil(IBANExtractor.extract(from: [
            "DEWA", "Premises No 1234567", "Total due AED 412.90",
        ]))
    }

    func testWrappedIBANStillReadsWhenTheChecksumProvesIt() {
        // The same join, with a real IBAN across it — unaffected by the guard.
        let iban = IBANExtractor.extract(from: ["Account details", "AE07 0331 2345", "6789 0123 456"])
        XCTAssertEqual(iban?.value, "AE070331234567890123456")
    }

    // MARK: - Document pipeline integration

    func testBankLetterYieldsIBANField() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Emirates NBD", "To whom it may concern",
            "This is to confirm the account details of Mr. Ahmed Ali",
            "Account Number: 1234567890",
            "IBAN: AE46 0090 0000 0012 3456 789",
        ])
        XCTAssertEqual(doc[.iban], "AE460090000000123456789")
    }

    func testHandwrittenIBANOnPlainPaperYieldsIBANField() {
        // No label, no layout, unknown document type — the IBAN still reads.
        let doc = DocumentParser.parse(recognizedLines: ["ae07 0331 2345 6789 0123 456"])
        XCTAssertEqual(doc[.iban], "AE070331234567890123456")
    }

    func testChequeIBANStillComesThroughChequeParser() {
        let cheque = ChequeParser.parse([
            "Emirates NBD", "MAIN BRANCH DUBAI", "Pay Saad Suhail or bearer",
            "IBAN AE07 0331 2345 6789 0123 456", "Account No 1234567890",
        ])
        XCTAssertEqual(cheque?.iban, "AE070331234567890123456")
    }

    // MARK: - extract(from document:) — what every IBAN source asks

    func testDocumentExtractPrefersTheParsedField() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Emirates NBD", "IBAN: AE46 0090 0000 0012 3456 789",
        ])
        XCTAssertEqual(IBANExtractor.extract(from: doc), "AE460090000000123456789")
    }

    func testDocumentExtractFallsBackToRawText() {
        // A document whose fields carry no IBAN at all — the raw lines still do.
        var doc = ScannedDocument(documentType: .unknown)
        doc.rawText = ["Salary transfer instruction", "GB29 NWBK 6016 1331 9268 19"]
        XCTAssertNil(doc.iban)
        XCTAssertEqual(IBANExtractor.extract(from: doc), "GB29NWBK60161331926819")
    }

    func testDocumentExtractReturnsNilWhenNothingCarriesAnIBAN() {
        var doc = ScannedDocument(documentType: .utilityBill)
        doc.rawText = ["DEWA", "Premises No 1234567", "Total due AED 412.90"]
        XCTAssertNil(IBANExtractor.extract(from: doc))
    }

    func testDocumentExtractTreatsABlankFieldAsNoIBAN() {
        var doc = ScannedDocument(documentType: .bankCheque)
        doc.fields = [ScannedField(key: .iban, label: "IBAN", value: "   ", category: .banking)]
        XCTAssertNil(IBANExtractor.extract(from: doc))
    }
}
