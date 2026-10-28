import XCTest
@testable import DocumentScannerKit

final class ScanModeTests: XCTestCase {

    private let chequeLines = [
        "Emirates NBD", "Pay  Gulf Trading Company LLC  or Order",
        "AED  15,250.00", "000123  0260101  01234567890  29",
    ]

    func testAutoModeLeavesExpectationOpen() {
        let doc = DocumentParser.parse(recognizedLines: chequeLines)
        XCTAssertNil(doc.expectedType)
        XCTAssertTrue(doc.matchesExpectedType)   // no expectation ⇒ always matches
    }

    func testManualModeMatchWhenCorrect() {
        let doc = DocumentParser.parse(recognizedLines: chequeLines, expecting: .bankCheque)
        XCTAssertEqual(doc.documentType, .bankCheque)
        XCTAssertEqual(doc.expectedType, .bankCheque)
        XCTAssertTrue(doc.matchesExpectedType)
    }

    func testManualModeMismatchIsFlagged() {
        // Caller declared a passport but presented a cheque.
        let doc = DocumentParser.parse(recognizedLines: chequeLines, expecting: .passportFront)
        XCTAssertEqual(doc.documentType, .bankCheque)
        XCTAssertEqual(doc.expectedType, .passportFront)
        XCTAssertFalse(doc.matchesExpectedType)   // caller can reject the capture
    }

    func testUnrecognizedUploadDoesNotInheritThePassportSlotType() {
        // Photo and PDF uploads are parsed without an expected type, just like
        // a camera still. An unreadable file must remain unknown so the host
        // shows its existing mismatch confirmation instead of filing junk as
        // a Passport Front.
        let doc = DocumentParser.parse(recognizedLines: ["blurred surface", "unreadable text"])
        XCTAssertEqual(doc.documentType, .unknown)
        XCTAssertNil(doc.expectedType)
    }

    func testScanModeExpectedType() {
        XCTAssertNil(ScanMode.auto.expectedType)
        XCTAssertEqual(ScanMode.manual(.visa).expectedType, .visa)
        XCTAssertTrue(ScanMode.auto.isAuto)
    }

    func testConfigurationAutoCaptureGating() {
        // Manual mode: only the declared type may auto-capture.
        let manual = ScannerConfiguration.manual(.bankCheque)
        XCTAssertTrue(manual.allowsAutoCapture(of: .bankCheque))
        XCTAssertFalse(manual.allowsAutoCapture(of: .passportFront))

        // Auto mode with a restriction list.
        let restricted = ScannerConfiguration(acceptedDocumentTypes: [.passportFront])
        XCTAssertTrue(restricted.allowsAutoCapture(of: .passportFront))
        XCTAssertFalse(restricted.allowsAutoCapture(of: .bankCheque))

        // Plain auto mode accepts everything.
        XCTAssertTrue(ScannerConfiguration.auto.allowsAutoCapture(of: .visa))
    }

    func testStrictGuideBoundaryIsOptInForPassportFrontOnly() {
        // Existing scan modes keep their historical fixed-guide behaviour.
        XCTAssertFalse(ScannerConfiguration.auto.enforcesGuideBoundary)
        XCTAssertFalse(ScannerConfiguration.manual(.emiratesIDFront).enforcesGuideBoundary)
        XCTAssertFalse(ScannerConfiguration.manual(.bankCheque).enforcesGuideBoundary)

        // The host opts Passport Front in before presenting it, so a close or
        // distant page cannot be captured from outside the visible MRZ frame.
        var passport = ScannerConfiguration(acceptedDocumentTypes: [.passportFront])
        passport.enforcesGuideBoundary = true
        XCTAssertTrue(passport.enforcesGuideBoundary)
    }

    func testContentGateConfigurationForIBANCapture() {
        // Off by default — ordinary scans keep the type-based readiness.
        XCTAssertNil(ScannerConfiguration.auto.autoCaptureContentGate)

        // The Direct Debit-style gate: ready only when an IBAN reads in the
        // live lines, so empty space or a not-yet-legible page never fires.
        var config = ScannerConfiguration(mode: .auto)
        config.autoCaptureContentGate = { lines in IBANExtractor.extract(from: lines) != nil }
        XCTAssertTrue(config.autoCaptureContentGate!(["IBAN: AE07 0331 2345 6789 0123 456"]))
        XCTAssertFalse(config.autoCaptureContentGate!([]))
        XCTAssertFalse(config.autoCaptureContentGate!(["a blank table surface"]))
    }
}
