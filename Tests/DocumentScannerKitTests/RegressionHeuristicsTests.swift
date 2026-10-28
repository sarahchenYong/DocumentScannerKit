import XCTest
import CoreGraphics
@testable import DocumentScannerKit

/// Pins the text-side heuristics that past regressions came from: MICR-line
/// detection, cheque-number scoring, MRZ block assembly, MRZ-over-OCR
/// priority, per-field confidence, and the image/JSON contract.
final class RegressionHeuristicsTests: XCTestCase {

    // MARK: - MICR line detection (looksLikeMICR)

    func testRecognizesRawMICRLinesWithSymbolJunk() {
        // Vision's actual renderings of E-13B bands from real scans.
        XCTAssertTrue(ChequeParser.looksLikeMICR("„000540262015208 0052758072010"))
        XCTAssertTrue(ChequeParser.looksLikeMICR("#0000540 26 20 1520°5275807 20 21º"))
        XCTAssertTrue(ChequeParser.looksLikeMICR("„00009b800 26 2015280528580 720 1l"))
        XCTAssertTrue(ChequeParser.looksLikeMICR("|l'001I* 1:123456789I: 9876543211\""))
        XCTAssertTrue(ChequeParser.looksLikeMICR("000123  0260101  01234567890  29"))
    }

    func testRejectsNonMICRLines() {
        XCTAssertFalse(ChequeParser.looksLikeMICR("IBAN: AE49 0260 0010 1527 5807 201"))
        XCTAssertFalse(ChequeParser.looksLikeMICR("Emirates NBD Bank (P.J.S.C.) is licensed"))
        XCTAssertFalse(ChequeParser.looksLikeMICR("784-1991-1234567-1"))     // Emirates ID no.
        XCTAssertFalse(ChequeParser.looksLikeMICR("Date 10/12/2025"))
        XCTAssertFalse(ChequeParser.looksLikeMICR("16000"))
    }

    // MARK: - Fallback MICR display

    func testDirtyMICRLineSurfacesDigitGroupsOnly() throws {
        let c = try XCTUnwrap(ChequeParser.parse([
            "Emirates NBD", "Pay John Smith or bearer", "AED 500.00",
            "„000540262015208 0052758072010",
        ]))
        XCTAssertEqual(c.micr, "000540262015208 0052758072010")   // junk marks gone
    }

    // MARK: - Cheque number heuristics

    func testChequeNumberIgnoresDigitsEmbeddedInCodeStrings() throws {
        // "112" sits inside a security code string adjacent to a cheque-number
        // label fragment; the standalone zero-padded serial must win.
        let c = try XCTUnwrap(ChequeParser.parse([
            "Emirates NBD", "000051", "WYyWXkAOhyK112DYkAlq", "heque Number",
            "Pay John Smith or bearer", "AED 500.00",
        ]))
        XCTAssertEqual(c.chequeNumber, "000051")
    }

    func testChequeNumberNotTakenFromAddressFragments() throws {
        // "NY 1000T" style fragments score below the acceptance gate.
        let c = try XCTUnwrap(ChequeParser.parse([
            "GLOBAL SOLUTIONS INC.", "Yock, NY 1000T",
            "PAY TO THE ORDER OF", "Jane Doe", "or bearer", "$1,500.00",
        ]))
        XCTAssertNil(c.chequeNumber)
    }

    func testShortSerialAcceptedNextToCheckLabel() throws {
        let c = try XCTUnwrap(ChequeParser.parse([
            "GLOBAL SOLUTIONS INC.", "CHECK NO.", "001",
            "PAY TO THE ORDER OF", "Jane Doe", "or bearer", "$1,500.00",
        ]))
        XCTAssertEqual(c.chequeNumber, "001")
    }

    // MARK: - MRZ candidate assembly

    func testFillerFreeTD1FirstLineIsACandidate() {
        // An Emirates ID's first TD1 line has no '<' at all.
        let blocks = MRZParser.candidateBlocks([
            "ILARE1485658931784199159658436",
            "9107061M2709031IND<<<<<<<<<<<1",
            "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
        ])
        XCTAssertTrue(blocks.contains { $0.hasPrefix("ILARE") })
    }

    func testProseAndHeadersAreNotMRZCandidates() {
        let blocks = MRZParser.candidateBlocks([
            "If you find this card, please return it to the issuing",
            "organization or to the nearest police station.",
            "PLEASE DO NOT WRITE BELOW THIS LINE HERE",
        ])
        XCTAssertTrue(blocks.isEmpty)
    }

    func testDualPassDuplicatesStillYieldTheValidBlock() {
        // Two OCR passes duplicate the MRZ lines; a consecutive window must
        // still recover a check-digit-valid TD1.
        let lines = [
            "ILARE1485658931784199159658436",
            "9107061M2709031IND<<<<<<<<<<<1",
            "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
            "Card Number 148565893",
            "ILARE1485658931784199159658436",
            "9107061M2709031IND<<<<<<<<<<<1",
            "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
        ]
        XCTAssertNotNil(MRZParser.firstValid(in: lines))
    }

    func testRepairsOCRLookalikesInTD1() throws {
        // Vision-style look-alike corruption: O for 0 in the date zones and
        // B/S for 8/5 in the numeric document number — the repair passes must
        // recover the exact same checksummed result as the clean read.
        let clean = MRZParser.firstValid(in: [
            "ILARE1485658931784199159658436",
            "9107061M2709031IND<<<<<<<<<<<1",
            "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
        ])
        let corrupted = MRZParser.firstValid(in: [
            "ILARE14B565893178419915965B436",
            "91O7O61M27O9O31IND<<<<<<<<<<<1",
            "DEVANGAM<YERRA<<SAMPLE<DEVANGAM",
        ])
        XCTAssertNotNil(clean)
        XCTAssertEqual(corrupted, clean)
    }

    func testRepairsOCRLookalikesInTD3() throws {
        // ICAO specimen passport with O↔0 swaps in dates and the nationality
        // zone corrupted with a digit look-alike.
        let clean = MRZParser.parse(
            "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n" +
            "L898902C36UTO7408122F1204159ZE184226B<<<<<10")
        let corrupted = MRZParser.parse(
            "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n" +
            "L898902C36UT074O8122F12O4159ZE184226B<<<<<10")
        XCTAssertNotNil(clean)
        XCTAssertEqual(corrupted?.documentNumber, clean?.documentNumber)
        XCTAssertEqual(corrupted?.dateOfBirth, clean?.dateOfBirth)
        XCTAssertEqual(corrupted?.expiryDate, clean?.expiryDate)
    }

    func testUnrepairableGarbageStillFails() {
        // A genuinely wrong digit (4 -> 1 in the birth date is not a
        // look-alike repair) must keep failing the core check digits.
        XCTAssertNil(MRZParser.parse(
            "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n" +
            "L898902C36UTO7108122F1204159ZE184226B<<<<<10"))
    }

    // MARK: - Visa / residence permit classification

    func testResidencePermitStaysVisaWhenPermitWordsPartiallyMissed() {
        // OCR variants of the same permit, each missing different label
        // words — every one must still classify as visa, never EID front,
        // even though all carry the 784 ID number.
        let variants: [[String]] = [
            ["UNITED ARAB EMIRATES", "RESIDENCE", "ID Number 784-1991-5965843-6",
             "Sponsor: MAG GLOBAL", "Passport No. C5002142"],
            ["UNITED ARAB EMIRATES", "784-1991-5965843-6",
             "Profession: ENGINEER", "U.I.D. No. 12345678"],
            ["RESIDENCE", "File 201/2023/1234567", "784-1991-5965843-6"],
        ]
        for lines in variants {
            let c = DocumentClassifier.classify(lines: lines, mrz: nil)
            XCTAssertEqual(c.kind, .visa, "misclassified: \(lines)")
        }
    }

    func testEmiratesIDFrontStillClassifiesAsIDFront() {
        // "Resident Identity Card" must NOT trip the permit context — the
        // 784 number keeps counting for the ID front.
        let c = DocumentClassifier.classify(lines: [
            "UNITED ARAB EMIRATES", "Resident Identity Card",
            "ID Number 784-1991-5965843-6", "Name: SAMPLE USER",
            "Nationality: India",
        ], mrz: nil)
        XCTAssertEqual(c.kind, .emiratesIDFront)
    }

    // MARK: - Trade licence

    func testTradeLicenseClassifiesAndParses() throws {
        let doc = DocumentParser.parse(recognizedLines: [
            "GOVERNMENT OF DUBAI", "Department of Economy and Tourism",
            "TRADE LICENSE", "License No. 654321",
            "Trade Name  ALPHA STAR TRADING L.L.C",
            "Legal Type  Limited Liability Company",
            "Issue Date 15/03/2024", "Expiry Date 14/03/2027",
            "Commercial Register No. 1234567",
            "Activity: General Trading",
        ])
        XCTAssertEqual(doc.documentType, .tradeLicense)
        XCTAssertEqual(doc[.tradeName], "ALPHA STAR TRADING L.L.C")
        XCTAssertEqual(doc[.legalForm], "Limited Liability Company")
        XCTAssertEqual(doc[.licenseNumber], "654321")
        XCTAssertEqual(doc[.registrationNumber], "1234567")
        XCTAssertEqual(doc[.dateOfIssue], "15/03/2024")
        XCTAssertEqual(doc[.dateOfExpiry], "14/03/2027")
        // The licence number belongs to the business here, not a vehicle.
        XCTAssertEqual(doc.fields.first { $0.key == .licenseNumber }?.category, .business)
    }

    func testTradeLicenseDoesNotStealDrivingLicence() {
        let c = DocumentClassifier.classify(lines: [
            "UNITED ARAB EMIRATES", "DRIVING LICENCE",
            "Licence No. 1234567", "Name SAMPLE USER",
            "Date of Birth 06/07/1991", "Class 3 Light Vehicle",
        ], mrz: nil)
        XCTAssertEqual(c.kind, .drivingLicense)
    }

    // MARK: - Emirates ID number from MRZ optional data

    func testEmiratesIDNumberFormatting() {
        XCTAssertEqual(DocumentParser.emiratesIDNumber(fromMRZOptional: "784199159658436"),
                       "784-1991-5965843-6")
        XCTAssertNil(DocumentParser.emiratesIDNumber(fromMRZOptional: "123199159658436")) // not 784
        XCTAssertNil(DocumentParser.emiratesIDNumber(fromMRZOptional: "78419915965843"))  // 14 digits
        XCTAssertNil(DocumentParser.emiratesIDNumber(fromMRZOptional: "78419915965843A")) // non-digit
        XCTAssertNil(DocumentParser.emiratesIDNumber(fromMRZOptional: ""))
    }

    // MARK: - Per-field confidence

    func testChequeFieldsCarryMechanismConfidences() throws {
        let doc = DocumentParser.parse(recognizedLines: [
            "Emirates NBD", "Date: 30/06/2026",
            "Pay  Gulf Trading Company LLC  or Order",
            "AED  Fifteen Thousand Two Hundred Fifty Dirhams Only",
            "AED  15,250.00", "000123  0260101  01234567890  29",
        ])
        XCTAssertTrue(doc.fields.allSatisfy { $0.confidence != nil })
        let bank = try XCTUnwrap(doc.fields.first { $0.key == .bankName }?.confidence)
        let payee = try XCTUnwrap(doc.fields.first { $0.key == .payeeName }?.confidence)
        XCTAssertGreaterThan(bank, payee)     // list match beats handwriting
        XCTAssertEqual(ScannedField(key: .bankName, label: "Bank", value: "x",
                                    category: .banking, confidence: 0.855).confidencePercent, 86)
    }

    // MARK: - ScannedDocument image contract

    func testImageIsCarriedButExcludedFromJSON() throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let jpeg = try XCTUnwrap(DocumentParser.jpegData(ctx.makeImage()!))
        XCTAssertGreaterThan(jpeg.count, 0)

        var doc = ScannedDocument(documentType: .bankCheque)
        doc.image = jpeg
        XCTAssertFalse(doc.jsonString.contains("image"))
        let decoded = try JSONDecoder().decode(ScannedDocument.self, from: doc.jsonData)
        XCTAssertNil(decoded.image)
        XCTAssertEqual(decoded.documentType, .bankCheque)
    }

    // MARK: - Capture slot mapping

    func testSlotNameMapping() {
        XCTAssertEqual(DocumentKind(slotName: "Passport Front Side"), .passportFront)
        XCTAssertEqual(DocumentKind(slotName: "Passport Back Side"), .passportBack)
        XCTAssertEqual(DocumentKind(slotName: "Passport Bio Page"), .passportFront)
        XCTAssertEqual(DocumentKind(slotName: "Passport Address Page"), .passportBack)
        XCTAssertEqual(DocumentKind(slotName: "PASSPORT"), .passportFront)
        XCTAssertEqual(DocumentKind(slotName: "Visa"), .visa)
        XCTAssertEqual(DocumentKind(slotName: "ID — Front"), .emiratesIDFront)
        XCTAssertEqual(DocumentKind(slotName: "ID — Back"), .emiratesIDBack)
        XCTAssertEqual(DocumentKind(slotName: "National ID"), .nationalID)
        XCTAssertEqual(DocumentKind(slotName: "National ID Card"), .nationalID)
        XCTAssertEqual(DocumentKind(slotName: "National ID Front Side"), .emiratesIDFront)
        XCTAssertEqual(DocumentKind(slotName: "National Id Back Side"), .emiratesIDBack)
        XCTAssertEqual(DocumentKind(slotName: "Emirates ID Front"), .emiratesIDFront)
        XCTAssertEqual(DocumentKind(slotName: "Trade Licence"), .tradeLicense)
        XCTAssertEqual(DocumentKind(slotName: "TRADE LICENSE"), .tradeLicense)
        XCTAssertNil(DocumentKind(slotName: "Salary Certificate"))
    }

    func testCaptureCompatibility() {
        XCTAssertTrue(DocumentKind.passportFront.isCaptureCompatible(with: .passportFront))
        XCTAssertFalse(DocumentKind.emiratesIDFront.isCaptureCompatible(with: .passportFront))
        XCTAssertFalse(DocumentKind.passportBack.isCaptureCompatible(with: .passportFront))
        XCTAssertFalse(DocumentKind.emiratesIDBack.isCaptureCompatible(with: .emiratesIDFront))
        // The generic national-ID classification stands in for an EID kind.
        XCTAssertTrue(DocumentKind.nationalID.isCaptureCompatible(with: .emiratesIDFront))
        XCTAssertTrue(DocumentKind.emiratesIDBack.isCaptureCompatible(with: .nationalID))
    }

    /// Regression: a passport captured while "National ID — Back" was the
    /// declared type must be FLAGGED, not silently accepted. The still-photo
    /// mismatch check (confidentMismatch) requires the classifier to name the
    /// passport confidently above the default 0.5 auto-confidence gate — pin
    /// that a typical passport data page (valid TD3 MRZ + printed labels)
    /// clears it and reads as incompatible with the declared ID kind.
    func testPassportStillFlagsMismatchAgainstNationalIDBack() {
        let lines = [
            "P<UTOERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 19),
            "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
            "PASSPORT",
            "Passport No L898902C3",
            "Date of Issue 15/03/2018",
        ]
        let c = DocumentClassifier.classify(lines: lines, mrz: MRZParser.firstValid(in: lines))
        XCTAssertEqual(c.kind, .passportFront)
        XCTAssertGreaterThanOrEqual(c.confidence, 0.5,
            "a clean passport still must clear the minimumAutoConfidence gate, or the wrong-document alert never fires")
        XCTAssertFalse(c.kind.isCaptureCompatible(with: .emiratesIDBack))
        XCTAssertFalse(c.kind.isCaptureCompatible(with: .nationalID))
    }

    // MARK: - Display names

    func testIDDisplayNamesDropTheEmiratesPrefix() {
        XCTAssertEqual(DocumentKind.emiratesIDFront.rawValue, "ID — Front")
        XCTAssertEqual(DocumentKind.emiratesIDBack.rawValue, "ID — Back")
    }
}
