import XCTest
import CoreGraphics
import ImageIO
@testable import DocumentScannerKit

/// End-to-end tests over real cheque photos in Tests/Fixtures (gitignored).
/// Each test skips when its fixture is absent so CI without the images passes.
final class ChequeImageTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DocumentScannerKitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Tests/Fixtures/\(name) not present")
        }
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    /// EXIF orientation matters for HEIC phone photos.
    private func loadFixtureOriented(_ name: String) throws -> (CGImage, CGImagePropertyOrientation) {
        let cg = try loadFixture(name)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let exif = (props?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init) ?? .up
        return (cg, exif)
    }

    func testEndToEndExtraction() throws {
        let cg = try loadFixture("cheque.png")
        let doc = try DocumentParser.parse(image: cg)

        // With dual-pass OCR + field merge, every field matches the cheque.
        XCTAssertEqual(doc.documentType, .bankCheque)
        XCTAssertEqual(doc.bankName, "Emirates NBD")
        XCTAssertEqual(doc[.branchName], "AL MURAQQABAT")
        XCTAssertEqual(doc.chequeNumber, "000051")          // clean printed number, not MICR
        XCTAssertEqual(doc.accountNumber, "1015275807201")
        XCTAssertEqual(doc.iban, "AE490260001015275807201")
        XCTAssertEqual(doc.amountInFigures, "16000")
        XCTAssertEqual(doc[.amountValue], "16000")
        XCTAssertEqual(doc[.amountInWords], "Sixteen Thousand Dirhams Only")
        XCTAssertEqual(doc[.currency], "AED")
        XCTAssertEqual(doc[.accountHolder], "SAMPLE USER")
        XCTAssertEqual(doc[.chequeDate], "10/12/2025")
        XCTAssertEqual(doc.payeeName, "Saad Suhail Salim Al Mukhaini Bahwan")
        // The MICR band must not have leaked its symbols into the cheque number.
        XCTAssertFalse(doc.chequeNumber?.contains("#") ?? false)
    }

    /// The second photo of the same cheque: the E-13B reader must decode the
    /// MICR band symbol-exactly — Vision alone drops the "1" glyphs and turns
    /// the ⑆/⑈ symbols into stray digits and punctuation.
    func testMICRBandDecoding() throws {
        let (cg, exif) = try loadFixtureOriented("cheque2.heic")
        let doc = try DocumentParser.parse(image: cg, orientation: exif)

        XCTAssertEqual(doc.documentType, .bankCheque)
        XCTAssertEqual(doc[.micrLine], "⑈000051⑆402620152⑆⑈5275807201⑈")
        XCTAssertEqual(doc.chequeNumber, "000051")          // from the MICR band
        XCTAssertEqual(doc[.routingNumber], "402620152")
        XCTAssertEqual(doc.accountNumber, "1015275807201")  // label wins over MICR tail
        // Each MICR segment individually, and all digits combined.
        XCTAssertEqual(doc[.micrChequeNumber], "000051")
        XCTAssertEqual(doc[.micrAccountNumber], "5275807201")
        XCTAssertEqual(doc[.receiptNumber], "0000514026201525275807201")
        XCTAssertEqual(doc.iban, "AE490260001015275807201")
        XCTAssertEqual(doc.amountInFigures, "16000")
        // Every field carries a confidence; MICR-derived ones use the measured
        // glyph-match quality (comfortably above the 0.72 accept threshold).
        XCTAssertTrue(doc.fields.allSatisfy { $0.confidence != nil })
        let micrConfidence = try XCTUnwrap(doc.fields.first { $0.key == .receiptNumber }?.confidence)
        XCTAssertGreaterThan(micrConfidence, 0.72)
        XCTAssertLessThanOrEqual(micrConfidence, 1.0)
    }
}

final class E13BParsingTests: XCTestCase {

    func testParseUAEBand() {
        let p = ChequeParser.parseE13B("⑈000051⑆402620152⑆⑈5275807201⑈")
        XCTAssertEqual(p.cheque, "000051")
        XCTAssertEqual(p.routing, "402620152")
        XCTAssertEqual(p.account, "5275807201")
    }

    func testParseBandWithoutLeadingOnUs() {
        let p = ChequeParser.parseE13B("123456⑆987654321⑆⑈13579⑈")
        XCTAssertEqual(p.cheque, "123456")
        XCTAssertEqual(p.routing, "987654321")
        XCTAssertEqual(p.account, "13579")
    }

    func testParseBandWithoutTransitPair() {
        let p = ChequeParser.parseE13B("⑈000051⑈5275807201⑈")
        XCTAssertEqual(p.cheque, "000051")
        XCTAssertNil(p.routing)
        XCTAssertEqual(p.account, "5275807201")
    }
}
