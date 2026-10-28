import XCTest
@testable import DocumentScannerKit

final class MRZParserTests: XCTestCase {

    func testTD3PassportSpecimen() throws {
        let line1 = "P<UTOERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 19)
        let line2 = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
        let r = try XCTUnwrap(MRZParser.parse(line1 + "\n" + line2))
        XCTAssertEqual(r.documentNumber, "L898902C3")
        XCTAssertEqual(r.surname, "ERIKSSON")
        XCTAssertEqual(r.givenNames, "ANNA MARIA")
        XCTAssertTrue(r.allChecksPassed)
    }

    func testTD1IDCardSpecimen() throws {
        let block = "I<UTOD231458907" + String(repeating: "<", count: 15) + "\n"
                  + "7408122F1204159UTO" + String(repeating: "<", count: 11) + "6" + "\n"
                  + "ERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 10)
        let r = try XCTUnwrap(MRZParser.parse(block))
        XCTAssertEqual(r.documentNumber, "D23145890")
        XCTAssertEqual(r.format, .td1)
        XCTAssertTrue(r.allChecksPassed)
    }

    func testRejectsGarbage() {
        XCTAssertNil(MRZParser.parse("HELLO\nWORLD"))
    }
}
