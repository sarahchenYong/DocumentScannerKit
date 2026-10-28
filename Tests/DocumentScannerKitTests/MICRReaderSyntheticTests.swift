import XCTest
import CoreGraphics
@testable import DocumentScannerKit

/// Regression tests for the E-13B MICR reader against synthetically rendered
/// bands — no camera or image fixtures needed, so they run everywhere. The
/// glyph shapes below are an independent copy of the E-13B module grids the
/// reader matches against; if the production templates drift, or any stage of
/// the pipeline (row isolation, binarization, segmentation, repair,
/// classification, structure checks) regresses, these fail.
final class MICRReaderSyntheticTests: XCTestCase {

    // MARK: - Synthetic E-13B rendering

    /// Independent copy of the E-13B glyph shapes (9 rows × N cols of ink).
    private static let shapes: [Character: [String]] = [
        "0": [".#####.", "#.....#", "#.....#", "#.....#", "#.....#",
              "#.....#", "#.....#", "#.....#", ".#####."],
        "1": ["##..", ".#..", ".#..", ".#..", ".#..",
              "####", "####", "####", "####"],
        "2": ["####", "...#", "...#", "...#", "####",
              "#...", "#...", "#...", "####"],
        "3": ["####", "...#", "...#", "...#", "####",
              "...#", "...#", "...#", "####"],
        "4": ["##....", "##....", "##....", "##....", "##....",
              "##..##", "######", "....##", "....##"],
        "5": ["#####", "#....", "#....", "#....", "#####",
              "....#", "....#", "....#", "#####"],
        "6": ["####..", "#..#..", "#.....", "#.....", "#.....",
              "######", "#....#", "#....#", "######"],
        "7": ["#####", "#...#", "#...#", "....#", "..##.",
              "..#..", "..#..", "..#..", "..#.."],
        "8": [".#####.", ".#...#.", ".#...#.", ".#...#.", "#######",
              "##...##", "##...##", "##...##", "#######"],
        "9": ["#####", "#...#", "#...#", "#...#", "#####",
              "...##", "...##", "...##", "...##"],
        "⑆": ["....###", "....###", "##..###", "##.....", "##.....",
              "##.....", "##..###", "....###", "....###"],
        "⑈": [".....####", "#.##.####", "#.##.####", "#.##.####", "#.##.####",
              "#.##.....", "#.##.....", "#.##.....", "#.##....."],
    ]

    /// Render a band string into a grayscale strip: white paper, black glyphs
    /// on a 9-row module grid, standard inter-glyph gap. Options simulate
    /// capture defects.
    private func renderBand(_ band: String,
                            module: Int = 5,
                            gapModules: Int = 3,
                            padModules: Int = 5,
                            paper: UInt8 = 245,
                            surroundRows: Int = 0,      // dark rows above/below
                            shearDegrees: Double = 0,
                            tightGapAfterGlyphs: Set<Int> = [],  // fused neighbours
                            dropTrailingColumns: Int = 0) -> CGImage {
        let glyphs = band.map { Self.shapes[$0]! }
        let glyphH = 9 * module
        // Per-glyph trailing gap: fused pairs sit one module apart — under the
        // symbol-part merge distance, so they segment as a single run.
        let gaps = (0..<glyphs.count).map { i in
            i == glyphs.count - 1 ? 0 : (tightGapAfterGlyphs.contains(i) ? 1 : gapModules)
        }
        let totalCols = glyphs.reduce(0) { $0 + $1[0].count } + gaps.reduce(0, +)
        let w = (totalCols + 2 * padModules) * module
        let h = glyphH + 2 * padModules * module + 2 * surroundRows
        var px = [UInt8](repeating: paper, count: w * h)

        // Dark surround (a mockup backdrop / cheque edge) at top and bottom.
        for y in 0..<surroundRows {
            for x in 0..<w { px[y * w + x] = 70; px[(h - 1 - y) * w + x] = 70 }
        }

        var xCursor = padModules * module
        let yTop = surroundRows + padModules * module
        var drawnCols = 0
        let dropFrom = totalCols - dropTrailingColumns
        for (index, rows) in glyphs.enumerated() {
            let cols = rows[0].count
            // The real on-us symbol ⑈ is shorter and narrower than the digits
            // (35×34 vs 45 tall); drawing it digit-sized would trip the
            // reader's over-wide split rule, which is keyed to glyph height.
            let cell = band[band.index(band.startIndex, offsetBy: index)] == "⑈"
                ? max(1, Int(Double(module) * 0.75)) : module
            for (r, row) in rows.enumerated() {
                for (c, char) in row.enumerated() where char == "#" {
                    if drawnCols + c >= dropFrom { continue }   // torn band edge
                    for dy in 0..<cell {
                        for dx in 0..<cell {
                            let x = xCursor + c * cell + dx
                            let y = yTop + r * cell + dy
                            px[y * w + x] = 15
                        }
                    }
                }
            }
            xCursor += (cols + gaps[index]) * module
            drawnCols += cols + gaps[index]
        }

        // Real captures are never two-level: sensor noise and antialiasing
        // spread the histogram. Perfectly flat synthetic art makes Otsu's
        // between-class variance plateau and collapse to the darkest level,
        // so add mild deterministic texture.
        for i in 0..<px.count { px[i] = px[i] &+ UInt8((i &* 2654435761) >> 28 & 7) }

        // Residual tilt: shear rows around the vertical centre.
        if shearDegrees != 0 {
            let t = tan(shearDegrees * .pi / 180)
            var sheared = [UInt8](repeating: paper, count: w * h)
            for y in 0..<h {
                let shift = Int((Double(y) - Double(h) / 2) * t)
                for x in 0..<w {
                    let nx = x + shift
                    if nx >= 0, nx < w { sheared[y * w + nx] = px[y * w + x] }
                }
            }
            px = sheared
        }

        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    private let band = "⑈000051⑆402620152⑆⑈5275807201⑈"

    // MARK: - Decode paths

    func testDecodesCleanBand() throws {
        let decoded = try XCTUnwrap(MICRReader.decode(strip: renderBand(band)))
        XCTAssertEqual(decoded.text, band)
        XCTAssertGreaterThan(decoded.confidence, 0.8)
    }

    func testDecodesEveryDigit() throws {
        let all = "⑈0123456789⑆987654321⑆⑈1234567890⑈"
        let decoded = try XCTUnwrap(MICRReader.decode(strip: renderBand(all)))
        XCTAssertEqual(decoded.text, all)
    }

    func testDecodesTinyBand() throws {
        // 2px modules → 18px glyphs: exercises the adaptive strip upscaling.
        let decoded = try XCTUnwrap(MICRReader.decode(strip: renderBand(band, module: 2)))
        XCTAssertEqual(decoded.text, band)
    }

    func testDecodesTiltedBand() throws {
        // Residual tilt from imperfect rectification: exercises the deskew.
        let decoded = try XCTUnwrap(MICRReader.decode(strip: renderBand(band, shearDegrees: 3)))
        XCTAssertEqual(decoded.text, band)
    }

    func testDecodesBandInsideDarkSurround() throws {
        // A mockup backdrop / cheque bottom edge must not fuse the glyphs:
        // exercises the partially-inked row isolation.
        let decoded = try XCTUnwrap(MICRReader.decode(strip: renderBand(band, surroundRows: 40)))
        XCTAssertEqual(decoded.text, band)
    }

    func testSplitsFusedDigitPairs() throws {
        // The digit pairs "0"→"2" and "7"→"5" sit one module apart — under
        // the symbol-part merge distance, they segment as single over-wide
        // runs, as blur produces on real captures: exercises the
        // faintest-column divide.
        let decoded = try XCTUnwrap(MICRReader.decode(
            strip: renderBand(band, tightGapAfterGlyphs: [9, 22])))
        XCTAssertEqual(decoded.text, band)
    }

    func testDropsTornTrailingSymbol() throws {
        // The trailing on-us symbol loses its block columns (torn band edge).
        // The unreadable narrow fragment must be dropped — every digit intact.
        let decoded = try XCTUnwrap(MICRReader.decode(
            strip: renderBand(band, dropTrailingColumns: 5)))
        XCTAssertEqual(decoded.text.filter(\.isNumber), band.filter(\.isNumber))
    }

    // MARK: - Rejection paths (all-or-nothing safety)

    func testRejectsBandWithoutSymbols() {
        // Digits alone are not a MICR band (structure check).
        XCTAssertNil(MICRReader.decode(strip: renderBand("0123456789012345")))
    }

    func testRejectsNonE13BShapes() {
        // Solid blocks sized like glyphs must not classify as anything.
        let module = 5
        let w = 20 * 10 * module, h = 19 * module
        var px = [UInt8](repeating: 245, count: w * h)
        for i in 0..<16 {                            // 16 solid squares
            let x0 = (5 + i * 12) * module, y0 = 5 * module
            for dy in 0..<(9 * module) {
                for dx in 0..<(7 * module) { px[(y0 + dy) * w + (x0 + dx)] = 15 }
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        XCTAssertNil(MICRReader.decode(strip: ctx.makeImage()!))
    }

    func testRejectsBlankStrip() {
        let ctx = CGContext(data: nil, width: 600, height: 80, bitsPerComponent: 8,
                            bytesPerRow: 600, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 80))
        XCTAssertNil(MICRReader.decode(strip: ctx.makeImage()!))
    }

    // MARK: - read(document:lineBox:) and field application

    /// A white "document" with the band drawn near the foot, plus the
    /// Vision-style normalized (bottom-left origin) box of the band line.
    private func documentWithBand() -> (image: CGImage, box: CGRect) {
        let strip = renderBand(band)
        let w = strip.width + 200, h = strip.height * 8
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.96, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext origin is bottom-left; place the band near the bottom.
        let stripRect = CGRect(x: 100, y: strip.height,
                               width: strip.width, height: strip.height)
        ctx.draw(strip, in: stripRect)
        let box = CGRect(x: stripRect.minX / CGFloat(w),
                         y: stripRect.minY / CGFloat(h),
                         width: stripRect.width / CGFloat(w),
                         height: stripRect.height / CGFloat(h))
        return (ctx.makeImage()!, box)
    }

    private func chequeDoc(fields: [ScannedField]) -> ScannedDocument {
        ScannedDocument(documentType: .bankCheque, confidence: 1, fields: fields)
    }

    func testReadLocatesBandFromLineBox() throws {
        let (image, box) = documentWithBand()
        let decoded = try XCTUnwrap(MICRReader.read(document: image, lineBox: box))
        XCTAssertEqual(decoded.text, band)
    }

    func testDecodedFieldsAreApplied() {
        let (image, box) = documentWithBand()
        let obs = [(text: "0000514026201525275807201", box: box)]
        let doc = DocumentParser.applyingDecodedMICR(
            to: chequeDoc(fields: []), attempts: [(image, obs)], lastResort: nil)
        XCTAssertEqual(doc[.micrLine], band)
        XCTAssertEqual(doc[.micrChequeNumber], "000051")
        XCTAssertEqual(doc[.routingNumber], "402620152")
        XCTAssertEqual(doc[.micrAccountNumber], "5275807201")
        XCTAssertEqual(doc[.receiptNumber], "0000514026201525275807201")
        XCTAssertEqual(doc[.accountNumber], "5275807201")   // filled the gap
        XCTAssertTrue(doc.classificationSignals.contains { $0.hasPrefix("MICR: E-13B decoded") })
    }

    func testDecodeContradictingAccountIsRejected() {
        let (image, box) = documentWithBand()
        let obs = [(text: "0000514026201525275807201", box: box)]
        let labelled = ScannedField(key: .accountNumber, label: "Account Number",
                                    value: "9998887776665", category: .banking, confidence: 0.9)
        let doc = DocumentParser.applyingDecodedMICR(
            to: chequeDoc(fields: [labelled]), attempts: [(image, obs)], lastResort: nil)
        XCTAssertNil(doc[.receiptNumber])
        XCTAssertNil(doc[.routingNumber])
        XCTAssertEqual(doc[.accountNumber], "9998887776665")   // untouched
        XCTAssertTrue(doc.classificationSignals.contains { $0.contains("contradicted the account") })
    }

    func testDecodeContradictingIBANBankCodeIsRejected() {
        let (image, box) = documentWithBand()
        let obs = [(text: "0000514026201525275807201", box: box)]
        // Bank code 033 ≠ the 026 embedded in the decoded routing number.
        let iban = ScannedField(key: .iban, label: "IBAN",
                                value: "AE070331234567890123456", category: .banking, confidence: 0.95)
        let doc = DocumentParser.applyingDecodedMICR(
            to: chequeDoc(fields: [iban]), attempts: [(image, obs)], lastResort: nil)
        XCTAssertNil(doc[.receiptNumber])
        XCTAssertTrue(doc.classificationSignals.contains { $0.contains("contradicted the IBAN") })
    }

    func testDecodeAgreeingWithAccountAndIBANIsAccepted() {
        let (image, box) = documentWithBand()
        let obs = [(text: "0000514026201525275807201", box: box)]
        let fields = [
            ScannedField(key: .accountNumber, label: "Account Number",
                         value: "1015275807201", category: .banking, confidence: 0.9),
            ScannedField(key: .iban, label: "IBAN",
                         value: "AE490260001015275807201", category: .banking, confidence: 0.95),
        ]
        let doc = DocumentParser.applyingDecodedMICR(
            to: chequeDoc(fields: fields), attempts: [(image, obs)], lastResort: nil)
        XCTAssertEqual(doc[.receiptNumber], "0000514026201525275807201")
        XCTAssertEqual(doc[.accountNumber], "1015275807201")   // label still wins
    }

    func testRetryingMICRSkipsWhenAlreadyDecoded() {
        let already = ScannedField(key: .receiptNumber, label: "Receipt Number",
                                   value: "0000514026201525275807201", category: .banking,
                                   confidence: 0.9)
        let doc = chequeDoc(fields: [already])
        let (image, _) = documentWithBand()
        XCTAssertEqual(DocumentParser.retryingMICR(doc, with: image, orientation: .up), doc)
    }
}
