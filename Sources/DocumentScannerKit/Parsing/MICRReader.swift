//
//  MICRReader.swift
//  DocumentScannerKit
//
//  Decodes the E-13B MICR band printed along the foot of a cheque. Vision's
//  text recognizer has no E-13B model: it drops the "1" glyphs (a bare stroke
//  over a solid block) and turns the transit ⑆ / on-us ⑈ symbols into stray
//  digits and punctuation. E-13B, however, was designed for machine reading —
//  14 fixed-shape glyphs on a uniform module grid — so this reader recovers
//  the band directly from pixels: crop the band (located by the OCR line's
//  bounding box), binarize with Otsu's threshold, segment glyphs by column
//  projection, and classify each glyph against shape templates. Every glyph
//  must match confidently or the whole read is rejected (returns nil), so a
//  failed decode can never be worse than the raw OCR fallback.
//

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

enum MICRReader {

    static let transit: Character = "⑆"   // routing-number delimiter
    static let onUs: Character = "⑈"      // cheque/account field delimiter

    /// Stage-by-stage decode tracing to stderr; set MICR_DEBUG=1 to enable.
    private static let traceEnabled = ProcessInfo.processInfo.environment["MICR_DEBUG"] != nil
    private static func trace(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        FileHandle.standardError.write("MICR| \(message())\n".data(using: .utf8)!)
    }

    // MARK: - Glyph templates

    /// One E-13B glyph as a 9-row shape sampled on its tight bounding box.
    /// `aspect` is the glyph's width/height, used to penalize matches against
    /// glyphs of a different footprint (e.g. the near-square on-us symbol vs
    /// the tall digits).
    private struct Template {
        let char: Character
        let rows: [String]        // 9 strings of '#' (ink) / '.' (blank)
        let aspect: Double
        let cols: Int
        let ink: [Double]         // rows flattened to 0/1
        init(_ char: Character, _ aspect: Double, _ rows: [String]) {
            self.char = char
            self.rows = rows
            self.aspect = aspect
            self.cols = rows[0].count
            self.ink = rows.flatMap { $0.map { $0 == "#" ? 1.0 : 0.0 } }
        }
    }

    /// Digit shapes measured from real UAE cheque scans; 3 and 9 are drawn
    /// from the E-13B specification (squared strokes, heavy lower/upper
    /// halves). The amount ⑇ and dash ⑉ symbols are not modeled — they don't
    /// appear on cheques in this SDK's target region, and any unmatched glyph
    /// safely fails the whole read rather than mis-reading.
    private static let templates: [Template] = [
        Template("0", 0.78, [".#####.",
                             "#.....#",
                             "#.....#",
                             "#.....#",
                             "#.....#",
                             "#.....#",
                             "#.....#",
                             "#.....#",
                             ".#####."]),
        Template("1", 0.44, ["##..",
                             ".#..",
                             ".#..",
                             ".#..",
                             ".#..",
                             "####",
                             "####",
                             "####",
                             "####"]),
        Template("2", 0.44, ["####",
                             "...#",
                             "...#",
                             "...#",
                             "####",
                             "#...",
                             "#...",
                             "#...",
                             "####"]),
        Template("3", 0.44, ["####",
                             "...#",
                             "...#",
                             "...#",
                             "####",
                             "...#",
                             "...#",
                             "...#",
                             "####"]),
        Template("4", 0.65, ["##....",
                             "##....",
                             "##....",
                             "##....",
                             "##....",
                             "##..##",
                             "######",
                             "....##",
                             "....##"]),
        Template("5", 0.55, ["#####",
                             "#....",
                             "#....",
                             "#....",
                             "#####",
                             "....#",
                             "....#",
                             "....#",
                             "#####"]),
        Template("6", 0.64, ["####..",
                             "#..#..",
                             "#.....",
                             "#.....",
                             "#.....",
                             "######",
                             "#....#",
                             "#....#",
                             "######"]),
        Template("7", 0.56, ["#####",
                             "#...#",
                             "#...#",
                             "....#",
                             "..##.",
                             "..#..",
                             "..#..",
                             "..#..",
                             "..#.."]),
        Template("8", 0.76, [".#####.",
                             ".#...#.",
                             ".#...#.",
                             ".#...#.",
                             "#######",
                             "##...##",
                             "##...##",
                             "##...##",
                             "#######"]),
        Template("9", 0.55, ["#####",
                             "#...#",
                             "#...#",
                             "#...#",
                             "#####",
                             "...##",
                             "...##",
                             "...##",
                             "...##"]),
        Template("⑆", 0.76, ["....###",
                             "....###",
                             "##..###",
                             "##.....",
                             "##.....",
                             "##.....",
                             "##..###",
                             "....###",
                             "....###"]),
        Template("⑈", 1.03, [".....####",
                             "#.##.####",
                             "#.##.####",
                             "#.##.####",
                             "#.##.####",
                             "#.##.....",
                             "#.##.....",
                             "#.##.....",
                             "#.##....."]),
    ]

    // MARK: - Reading

    /// Decode the E-13B band of a rectified cheque image. `lineBox` is the
    /// Vision-normalized bounding box (origin bottom-left) of the OCR line that
    /// looked like the MICR band. Returns the decoded band (digits plus ⑆/⑈
    /// symbols) with its match confidence, or nil when any glyph fails to
    /// classify confidently.
    static func read(document: CGImage, lineBox: CGRect) -> (text: String, confidence: Double)? {
        let W = CGFloat(document.width), H = CGFloat(document.height)
        // Pad generously: sideways for the leading/trailing symbols OCR often
        // clips, vertically because the box hugs the x-height.
        let padX = max(0.015 * W, 0.9 * lineBox.height * H)
        let padY = 0.6 * lineBox.height * H
        let rect = CGRect(x: lineBox.minX * W - padX,
                          y: (1 - lineBox.maxY) * H - padY,
                          width: lineBox.width * W + 2 * padX,
                          height: lineBox.height * H + 2 * padY)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !rect.isEmpty, let strip = document.cropping(to: rect) else { return nil }
        return decode(strip: strip)
    }

    /// Decode a cropped band strip: find the text rows → binarize → deskew →
    /// segment → classify. The confidence blends the average and the weakest
    /// glyph match, so one marginal glyph drags the whole band down.
    ///
    /// Binarization runs up to twice: cheque paper carries three tone classes
    /// (white paper, light security pattern, black E-13B ink), and Otsu's
    /// two-class split can lump the pattern in with the ink — fusing the band
    /// into blobs. If the standard split fails, a stricter threshold computed
    /// within the dark class alone (black ink is the darkest mode) is tried.
    static func decode(strip: CGImage) -> (text: String, confidence: Double)? {
        // Small strips (distant shots, downscaled frames) leave glyph strokes
        // only ~1px wide — too thin to segment or template-match. Render them
        // up so glyphs are comfortably tall (~130px of strip).
        let scale = max(1, min(4, Int((130.0 / Double(strip.height)).rounded(.up))))
        guard let bitmap = grayscale(strip, scale: scale) else { return nil }
        let (px, w, fullH) = bitmap
        if let result = decode(px: px, w: w, fullH: fullH, scale: scale, strict: false) {
            return result
        }
        trace("standard threshold failed — retrying strict")
        return decode(px: px, w: w, fullH: fullH, scale: scale, strict: true)
    }

    private static func decode(px: [UInt8], w: Int, fullH: Int, scale: Int,
                               strict: Bool) -> (text: String, confidence: Double)? {
        func threshold(for pixels: [UInt8]) -> UInt8 {
            let t = otsu(pixels)
            guard strict else { return t }
            let dark = pixels.filter { $0 < t }
            return dark.isEmpty ? t : min(t, otsu(dark))
        }
        // Isolate the rows that actually carry the glyphs. The padded crop can
        // include the cheque's bottom edge, a dark surround (screenshots,
        // mockups), or neighbouring print (a counterfoil's footer): rows that
        // binarize nearly solid fuse everything, blank rows are padding, and
        // the glyph rows need not be the longest partially-inked run. Try the
        // few longest candidate runs; the classifier arbitrates.
        let runs = textRowRanges(px: px, w: w, h: fullH, threshold: threshold(for: px))
        guard !runs.isEmpty else {
            trace("no text rows (strip \(w)x\(fullH), scale \(scale))"); return nil
        }
        for band in runs {
            if let result = decode(px: px, w: w, band: band, strict: strict) { return result }
        }
        return nil
    }

    private static func decode(px: [UInt8], w: Int, band: Range<Int>,
                               strict: Bool) -> (text: String, confidence: Double)? {
        func threshold(for pixels: [UInt8]) -> UInt8 {
            let t = otsu(pixels)
            guard strict else { return t }
            let dark = pixels.filter { $0 < t }
            return dark.isEmpty ? t : min(t, otsu(dark))
        }
        let slice = Array(px[(band.lowerBound * w)..<(band.upperBound * w)])
        let h = band.count
        let sliceThreshold = threshold(for: slice)
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { ink[i] = slice[i] < sliceThreshold }
        // A believable band is mostly paper with a thin line of ink.
        let inkFraction = Double(ink.lazy.filter { $0 }.count) / Double(w * h)
        guard inkFraction > 0.005, inkFraction < 0.5 else { trace("ink fraction \(inkFraction)"); return nil }

        ink = deskewed(ink, w: w, h: h)
        let glyphs = segment(ink: ink, w: w, h: h)
        trace("band rows \(band) h\(h) glyphs \(glyphs.count)")
        guard glyphs.count >= 12, glyphs.count <= 65 else { return nil }

        // Classify with bounded repair: a glyph that won't classify may be two
        // characters bridged by smear right at the split threshold, or a
        // symbol fragment orphaned by an over-eager split. Try cutting it at
        // its faintest interior column, then try absorbing the next part —
        // accepting only what then classifies confidently.
        let maxH = glyphs.map { $0.y1 - $0.y0 + 1 }.max() ?? 0
        let expectedW = 0.78 * Double(maxH)

        func trimmed(_ x0: Int, _ x1: Int) -> Glyph? {
            var y0 = h, y1 = -1
            for y in 0..<h {
                for x in x0...x1 where ink[y * w + x] { y0 = min(y0, y); y1 = max(y1, y) }
            }
            return y1 >= y0 ? Glyph(x0: x0, x1: x1, y0: y0, y1: y1) : nil
        }
        func splitAtFaintest(_ g: Glyph) -> (Glyph, Glyph)? {
            let margin = max(2, Int(0.25 * Double(g.x1 - g.x0 + 1)))
            guard g.x0 + margin < g.x1 - margin else { return nil }
            var cut = g.x0 + margin, cutInk = Int.max
            for x in (g.x0 + margin)...(g.x1 - margin) {
                var col = 0
                for y in g.y0...g.y1 where ink[y * w + x] { col += 1 }
                if col < cutInk { cutInk = col; cut = x }
            }
            guard let l = trimmed(g.x0, cut), let r = trimmed(min(cut + 1, g.x1), g.x1) else { return nil }
            return (l, r)
        }

        var parts = glyphs
        var out = ""
        var scores: [Double] = []
        var i = 0, repairs = 0
        while i < parts.count {
            if let match = classify(glyph: parts[i], ink: ink, w: w) {
                out.append(match.char)
                scores.append(match.score)
                i += 1
                continue
            }
            repairs += 1
            trace("repair #\(repairs) after '\(out)' on w\(parts[i].x1 - parts[i].x0 + 1) h\(parts[i].y1 - parts[i].y0 + 1)")
            guard repairs <= 6 else { trace("repair budget exhausted"); return nil }
            if let (l, r) = splitAtFaintest(parts[i]), classify(glyph: l, ink: ink, w: w) != nil {
                parts[i] = l
                parts.insert(r, at: i + 1)
                continue
            }
            if i + 1 < parts.count {
                let merged = Glyph(x0: parts[i].x0, x1: parts[i + 1].x1,
                                   y0: min(parts[i].y0, parts[i + 1].y0),
                                   y1: max(parts[i].y1, parts[i + 1].y1))
                if Double(merged.x1 - merged.x0 + 1) <= 1.25 * expectedW,
                   classify(glyph: merged, ink: ink, w: w) != nil {
                    parts[i] = merged
                    parts.remove(at: i + 1)
                    continue
                }
            }
            // Torn boundary-symbol pieces: an unreadable NARROW fragment
            // opening the band, or a run of them closing it once the decoded
            // structure is already complete, are droppable — the interior
            // delimiters carry the structure. An unreadable interior or
            // full-width glyph (possibly a real digit) still rejects the read.
            let narrow = { (g: Glyph) in Double(g.x1 - g.x0 + 1) < 0.7 * expectedW }
            if narrow(parts[i]) {
                if i == 0 { parts.remove(at: 0); continue }
                if parts[i...].allSatisfy(narrow),
                   out.filter({ $0 == transit || $0 == onUs }).count >= 2,
                   out.filter(\.isNumber).count >= 10 {
                    break
                }
            }
            trace("unrepairable after '\(out)'")
            return nil
        }
        // Structural sanity: a MICR band has at least one delimiter pair and a
        // real quantity of digits.
        let symbols = out.filter { $0 == transit || $0 == onUs }.count
        let digits = out.filter(\.isNumber).count
        guard symbols >= 2, digits >= 10 else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let confidence = min(1, (mean + (scores.min() ?? mean)) / 2)
        return (out, confidence)
    }

    // MARK: - Segmentation

    /// Contiguous runs of rows that are partially inked — more than speckle,
    /// less than a solid border — i.e. rows that could carry the glyphs. The
    /// longest few, longest first (the band isn't always the longest run when
    /// other print shares the strip).
    private static func textRowRanges(px: [UInt8], w: Int, h: Int, threshold: UInt8) -> [Range<Int>] {
        var runs: [Range<Int>] = [], start: Int?
        func close(_ end: Int) {
            if let s = start, end - s >= 8 { runs.append(s..<end) }
            start = nil
        }
        for y in 0..<h {
            var inked = 0
            for x in 0..<w where px[y * w + x] < threshold { inked += 1 }
            let frac = Double(inked) / Double(w)
            if frac > 0.02, frac < 0.7 {
                if start == nil { start = y }
            } else {
                close(y)
            }
        }
        close(h)
        return Array(runs.sorted { $0.count > $1.count }.prefix(3))
    }

    /// Residual tilt from imperfect rectification leans every glyph, closing
    /// the gaps between them until neighbours fuse. Try a range of small shear
    /// angles and keep the one that concentrates ink into the fewest, densest
    /// columns (the classic projection-profile deskew).
    private static func deskewed(_ ink: [Bool], w: Int, h: Int) -> [Bool] {
        func sheared(_ tangent: Double) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                let shift = Int((Double(y) - Double(h) / 2) * tangent)
                for x in 0..<w where ink[y * w + x] {
                    let nx = x + shift
                    if nx >= 0, nx < w { out[y * w + nx] = true }
                }
            }
            return out
        }
        func sharpness(_ bits: [Bool]) -> Double {
            var score = 0.0
            for x in 0..<w {
                var col = 0
                for y in 0..<h where bits[y * w + x] { col += 1 }
                score += Double(col * col)
            }
            return score
        }
        var best = (tangent: 0.0, score: sharpness(ink))
        for degrees in stride(from: -4.0, through: 4.0, by: 0.5) where degrees != 0 {
            let tangent = tan(degrees * .pi / 180)
            let score = sharpness(sheared(tangent))
            if score > best.score { best = (tangent, score) }
        }
        return best.tangent == 0 ? ink : sheared(best.tangent)
    }

    private struct Glyph { var x0, x1, y0, y1: Int }

    /// Split the strip into glyphs by column projection. E-13B symbols are
    /// drawn as separated bars/blocks, so segments closer than a fraction of
    /// the glyph height — and whose union stays within one glyph width — are
    /// the parts of a single symbol and get merged.
    private static func segment(ink: [Bool], w: Int, h: Int) -> [Glyph] {
        var colInk = [Int](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] { colInk[x] += 1 }
        }
        var runs: [(Int, Int)] = []
        var start: Int?
        for x in 0..<w {
            if colInk[x] >= 2 {
                if start == nil { start = x }
            } else if let s = start {
                runs.append((s, x - 1)); start = nil
            }
        }
        if let s = start { runs.append((s, w - 1)) }

        func trimmed(_ x0: Int, _ x1: Int) -> Glyph? {
            var y0 = h, y1 = -1
            for y in 0..<h {
                for x in x0...x1 where ink[y * w + x] {
                    y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            return y1 >= y0 ? Glyph(x0: x0, x1: x1, y0: y0, y1: y1) : nil
        }
        var parts = runs.compactMap { trimmed($0.0, $0.1) }
        let maxH = parts.map { $0.y1 - $0.y0 + 1 }.max() ?? 0
        guard maxH > 8 else { return [] }

        // Ink smear (blur, low resolution, slight tilt) can bridge the gap
        // between neighbouring glyphs into a single run. E-13B fixes glyph
        // geometry — 0.091" wide on 0.117" height — so any run wider than
        // ~1.15× the expected width is a fusion; split it at its faintest
        // interior column and re-trim the halves.
        let expectedW = 0.78 * Double(maxH)
        var singles: [Glyph] = []
        func divide(_ g: Glyph) {
            let width = g.x1 - g.x0 + 1
            let margin = max(2, Int(0.35 * expectedW))
            guard Double(width) > 1.15 * expectedW, g.x0 + margin < g.x1 - margin else {
                singles.append(g); return
            }
            var cut = g.x0 + margin
            for x in (g.x0 + margin)...(g.x1 - margin) where colInk[x] < colInk[cut] { cut = x }
            if let left = trimmed(g.x0, cut) { divide(left) }
            if let right = trimmed(min(cut + 1, g.x1), g.x1) { divide(right) }
        }
        parts.forEach(divide)
        parts = singles

        // Speckle rejection: drop crumbs far smaller than the dominant glyph.
        let maxW = parts.map { $0.x1 - $0.x0 + 1 }.max() ?? 0
        guard maxW > 4 else { return [] }
        parts.removeAll { ($0.y1 - $0.y0 + 1) * ($0.x1 - $0.x0 + 1) < (maxH * maxW) / 40 }

        // Merge symbol parts: near neighbours whose union is still glyph-wide.
        let gapLimit = Int(0.26 * Double(maxH))
        var glyphs: [Glyph] = []
        for p in parts {
            if let last = glyphs.last,
               p.x0 - last.x1 - 1 <= gapLimit,
               p.x1 - last.x0 + 1 <= Int(1.05 * Double(maxW)) {
                glyphs[glyphs.count - 1] = Glyph(x0: last.x0, x1: p.x1,
                                                 y0: min(last.y0, p.y0),
                                                 y1: max(last.y1, p.y1))
            } else {
                glyphs.append(p)
            }
        }
        return glyphs
    }

    // MARK: - Classification

    /// Match one glyph against every template: resample its tight box onto the
    /// template's 9×cols grid and score by mean ink agreement, penalized by
    /// footprint (aspect-ratio) mismatch. Nil unless the winner is confident.
    private static func classify(glyph: Glyph, ink: [Bool], w: Int) -> (char: Character, score: Double)? {
        let gw = glyph.x1 - glyph.x0 + 1, gh = glyph.y1 - glyph.y0 + 1
        guard gw > 2, gh > 2 else { return nil }
        let aspect = Double(gw) / Double(gh)

        var best: (char: Character, score: Double)?
        for t in templates {
            var sum = [Double](repeating: 0, count: t.cols * 9)
            var cnt = [Int](repeating: 0, count: t.cols * 9)
            for y in glyph.y0...glyph.y1 {
                let r = min(8, (y - glyph.y0) * 9 / gh)
                for x in glyph.x0...glyph.x1 {
                    let c = min(t.cols - 1, (x - glyph.x0) * t.cols / gw)
                    sum[r * t.cols + c] += ink[y * w + x] ? 1 : 0
                    cnt[r * t.cols + c] += 1
                }
            }
            var diff = 0.0
            for i in 0..<(t.cols * 9) {
                diff += abs(sum[i] / Double(max(1, cnt[i])) - t.ink[i])
            }
            let score = 1 - diff / Double(t.cols * 9) - 0.8 * abs(aspect - t.aspect)
            if best == nil || score > best!.score { best = (t.char, score) }
        }
        guard let b = best, b.score >= 0.72 else {
            if let b = best {
                trace("glyph rejected: best '\(b.char)' \(String(format: "%.2f", b.score)) aspect \(String(format: "%.2f", aspect))")
            }
            return nil
        }
        return b
    }

    // MARK: - Pixels

    private static func grayscale(_ cg: CGImage, scale: Int = 1) -> (px: [UInt8], w: Int, h: Int)? {
        let w = cg.width * scale, h = cg.height * scale
        guard w > 0, h > 0, w * h <= 16_000_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }

    /// Otsu's method: the threshold that best separates ink from paper.
    private static func otsu(_ px: [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for p in px { hist[Int(p)] += 1 }
        let total = Double(px.count)
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i) * Double(hist[i]) }
        var sumB = 0.0, weightB = 0.0, bestVar = 0.0, threshold = 127
        for i in 0..<256 {
            weightB += Double(hist[i])
            guard weightB > 0 else { continue }
            let weightF = total - weightB
            guard weightF > 0 else { break }
            sumB += Double(i) * Double(hist[i])
            let meanB = sumB / weightB, meanF = (sumAll - sumB) / weightF
            let between = weightB * weightF * (meanB - meanF) * (meanB - meanF)
            if between > bestVar { bestVar = between; threshold = i }
        }
        return UInt8(threshold)
    }
}
#endif
