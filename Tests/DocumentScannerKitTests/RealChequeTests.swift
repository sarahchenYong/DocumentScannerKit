import XCTest
@testable import DocumentScannerKit

/// Regression test built from the *actual* Vision OCR output of a real
/// photographed Emirates NBD cheque (handwritten payee/amount, a counterfoil
/// stub, a noisy MICR band, and a split date). It guards against the bugs that
/// real-world OCR exposed: payee = "against", missing cheque number, missing
/// amount, and date/MICR fragments leaking into numeric fields.
final class RealChequeTests: XCTestCase {

    // Verbatim OCR lines (Vision, accurate level) from the sample cheque.
    private let lines = [
        "d rủ", "Luiu pos", "Emirates NBD", "000051", "WYyWXkAOhyK112DYkAlq",
        "heque Number", "CHEQUE", "AL MURAQOABAT",
        "Emirates NBD Bank (P.J.S.C.) is licensed by the Central Bank of the UAE.",
        "95", "ate 10R", "12095", "Date 10", "Loga g0os1", "Pay against",
        "сиiлho", "saad suhail Salim Al Mukhaini B", "Bahwan", "- Banwan",
        "this cheque", "aloby gi", "or bearer", "Hhaudand Dishams oaly",
        "evious Balance", "poj", "Speteen", "Dirhams", "Đ", "¡posited", "aaal",
        "SAMPLE USER", "tal", "giogil", "A/CNo. 1015275807201",
        "Signature(s)", "uul lio", "-IBAN: AE49 0260 0010 1527 5807 201",
        "Please do not write below this line", "16000", "is Cheque",
        "„00009b800 26 2015280528580 720 1l", "rrent Balance",
    ]

    func testClassifiedAsCheque() {
        XCTAssertEqual(DocumentParser.parse(recognizedLines: lines).documentType, .bankCheque)
    }

    func testCorrectFields() throws {
        let c = try XCTUnwrap(ChequeParser.parse(lines))
        XCTAssertEqual(c.bank, "Emirates NBD")
        XCTAssertEqual(c.chequeNumber, "000051")        // not the stub amount 16000
        XCTAssertEqual(c.accountNumber, "1015275807201")
        XCTAssertEqual(c.iban, "AE490260001015275807201")
        XCTAssertEqual(c.amountInFigures, "16000")       // not the date fragment 12095
        XCTAssertEqual(c.amountValue, Decimal(16000))
        XCTAssertEqual(c.currency, "AED")
        // Amount in words regenerated from the figure (the handwritten line is
        // too garbled to read).
        XCTAssertEqual(c.amountInWords, "Sixteen Thousand Dirhams Only")
        // Printed account holder, distinct from the branch.
        XCTAssertEqual(c.accountHolder, "SAMPLE USER")
        XCTAssertNotNil(c.branch)
        XCTAssertNotEqual(c.branch, c.accountHolder)
        // Handwritten payee — full name incl. the wrapped "Bahwan", not "against".
        let payee = try XCTUnwrap(c.payee).lowercased()
        XCTAssertTrue(payee.contains("mukhaini"))
        XCTAssertTrue(payee.contains("bahwan"))
        XCTAssertFalse(payee.contains("against"))
        // The cheque number must never equal the account number.
        XCTAssertNotEqual(c.chequeNumber, c.accountNumber)
    }
}
