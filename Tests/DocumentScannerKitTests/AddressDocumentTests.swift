import XCTest
@testable import DocumentScannerKit

final class AddressDocumentTests: XCTestCase {
    func testDEWABillClassifiesAndKeepsMultilineServiceAddress() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Dubai Electricity and Water Authority (DEWA)", "Tax Invoice",
            "Customer Account Number: 1234567890", "Service Address: Flat 1204, Marina Heights Tower",
            "Al Marsa Street", "Dubai, United Arab Emirates", "Amount Due AED 380.50",
        ])
        XCTAssertEqual(doc.documentType, .utilityBill)
        XCTAssertEqual(doc[.address], "Flat 1204, Marina Heights Tower, Al Marsa Street, Dubai, United Arab Emirates")
    }

    func testBusinessCardFindsUnlabelledAddress() {
        let doc = DocumentParser.parse(recognizedLines: [
            "ALPHA STAR TRADING L.L.C.", "Sarah Khan | Sales Manager", "Mobile: +971 50 123 4567",
            "Office 405, Business Bay Tower", "Marasi Drive, Dubai, UAE", "www.alphastar.example",
        ])
        XCTAssertEqual(doc.documentType, .businessCard)
        XCTAssertEqual(doc[.address], "Office 405, Business Bay Tower, Marasi Drive, Dubai, UAE")
    }

    func testBinghattiStyleBusinessCardKeepsOfficeBuildingAndLocation() {
        let doc = DocumentParser.parse(recognizedLines: [
            "BINGHATTI", "Amira Albesh r", "Customer Experience Ambassador",
            "Binghatti Corporate Office", "6th Floor, H Hotel Office Tower", "Dubai, UAE",
            "+971 56 967 3271", "amira.albeshr@binghatti.com", "www.binghatti.com",
        ])
        XCTAssertEqual(doc.documentType, .businessCard)
        XCTAssertEqual(doc[.address], "Binghatti Corporate Office, 6th Floor, H Hotel Office Tower, Dubai, UAE")
    }

    func testHandwrittenStyleAddressNoteUsesLabelAndContinuationLines() {
        let doc = DocumentParser.parse(recognizedLines: ["Address", "Villa 17, Al Noor Street", "Al Barsha 2", "Dubai UAE"])
        XCTAssertEqual(doc.documentType, .addressNote)
        XCTAssertEqual(doc[.address], "Villa 17, Al Noor Street, Al Barsha 2, Dubai UAE")
    }

    func testPassportBackStillWinsOverGenericAddressNoteClassification() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Address: 12 Main Street, Dubai", "Father's Name: John Doe", "Mother's Name: Mary Doe", "Spouse: Jane Doe",
        ])
        XCTAssertEqual(doc.documentType, .passportBack)
        XCTAssertEqual(doc[.address], "12 Main Street, Dubai")
    }

    func testPassportBackAddressDropsMergedIssueDetailsAndTrailingOCRJunk() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Address: 409-220A IRA NEEDLES BLVD, KITCHENER, ONTARIO, N2N 0C4, anl sadenastesa Date and Place of isue",
        ], expecting: .passportBack)

        XCTAssertEqual(doc[.address], "409-220A IRA NEEDLES BLVD, KITCHENER, ONTARIO, N2N 0C4")
    }

    func testWorldwideAddressLabelsPopulateStructuredFields() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Street: Musterstraße 12", "Postal Code: 10115", "City: Berlin", "Country: Germany",
        ])

        XCTAssertEqual(doc[.street], "Musterstraße 12")
        XCTAssertEqual(doc[.postalCode], "10115")
        XCTAssertEqual(doc[.city], "Berlin")
        XCTAssertEqual(doc[.country], "Germany")
    }

    func testUnlabelledInternationalAddressUsesCountryRecognition() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Musterstraße 12", "10115 Berlin", "Germany",
        ])

        XCTAssertEqual(doc[.address], "Musterstraße 12, 10115 Berlin, Germany")
    }

    func testBusinessCardAddressDropsTrailingPhoneNumber() {
        let doc = DocumentParser.parse(recognizedLines: [
            "Address: 6th Floor, H Hotel Office Tower, Dubai, UAE | +9714 355 5888",
        ])

        XCTAssertEqual(doc[.address], "6th Floor, H Hotel Office Tower, Dubai, UAE")
    }

    // MARK: - Whole-document scans

    func testWholeDocumentPrefersOccupantAddressLabelOverLetterheadAddress() {
        // The user scans the entire letter, not just the address block; the
        // issuer's own address sits under a bare "Address" in the letterhead
        // while the customer's is under "Residential Address" further down.
        let doc = DocumentParser.parse(recognizedLines: [
            "GULF UTILITIES COMPANY", "Address: Office 900, Corporate Park, Abu Dhabi",
            "Statement of account", "Customer: Ahmed Ali",
            "Residential Address: Villa 22, Al Wasl Road", "Umm Suqeim 2", "Dubai, UAE",
            "Amount due: AED 420.00",
        ])
        XCTAssertEqual(doc[.address], "Villa 22, Al Wasl Road, Umm Suqeim 2, Dubai, UAE")
    }

    func testHandwrittenAddressWithoutAnyLabelUsesEmirateCue() {
        // A hand-written paper: no "Address" label anywhere — the emirate
        // name is the location cue.
        let doc = DocumentParser.parse(recognizedLines: [
            "Villa 17, Al Noor Street", "Al Barsha 2", "Dubai",
        ])
        XCTAssertEqual(doc[.address], "Villa 17, Al Noor Street, Al Barsha 2, Dubai")
    }

    func testHandwrittenNoteWithoutCityStillReadsAsAddress() {
        // No label, no city or country at all — a sparse page whose lines
        // are anchored by explicit street words still yields the address.
        let doc = DocumentParser.parse(recognizedLines: [
            "Flat 304, Marina Heights Building", "Al Marsa Street",
        ])
        XCTAssertEqual(doc[.address], "Flat 304, Marina Heights Building, Al Marsa Street")
    }

    func testProseParagraphIsNotMistakenForAnAddress() {
        let doc = DocumentParser.parse(recognizedLines: [
            "The meeting was nearly finished", "when the statement arrived",
        ])
        XCTAssertNil(doc[.address])
    }

    func testFullPageBillWithInterleavedAmountsNeverTakesBillingLinesAsAddress() {
        // A real DEWA bill OCRs two columns interleaved: the premise block is
        // shot through with billing-summary lines and currency amounts (the
        // dirham symbol mangles to "Đ"/"B"). None of that is ever an address.
        let doc = DocumentParser.parse(recognizedLines: [
            "GOVERNMENT OF DUBAI", "Dubai Electricity &Water Authority", "Bill Summary",
            "Account Number", "2057416763", "JOHN SAMPLE HOLDER",
            "Đ334.44", "Total", "312", "Additional charges:",
            "618-NADD AL SHIBA FIRST", "Premise Number: 618021582", "Đ728.26",
            "Current month total:", "Premise Type: RESIDENTIAL - FLAT",
            "Previous bill balance:", "Đ596.27", "PO Box: 5328, Dubai, UAE", "฿0.00",
        ])
        XCTAssertEqual(doc.documentType, .utilityBill)
        XCTAssertEqual(doc[.address], "PO Box: 5328, Dubai, UAE")
    }
}
