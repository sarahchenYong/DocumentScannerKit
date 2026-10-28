//
//  DocumentReader.swift
//  DocumentScannerKit
//
//  The non-camera half of the kit. `DocumentScanner` presents the camera;
//  `DocumentReader` takes what the camera never saw — a photo out of the
//  library, a PDF out of Files, an image handed over by a drag & drop or a
//  share sheet — and runs it through the same OCR and the same parsers, so
//  a picked document and a scanned one are read identically.
//
//      // A whole document
//      for page in DocumentReader.pageImages(image: picked) {
//          let doc = try DocumentParser.parse(image: page.cgImage,
//                                             orientation: page.orientation)
//      }
//
//      // Just one value, searched page by page
//      DocumentReader.readIBAN(pdfFilePath: url) { iban in ... }
//

#if canImport(UIKit)
import UIKit
import PDFKit
import ImageIO

public enum DocumentReader {

    /// One page, ready for `DocumentParser`.
    public typealias Page = (cgImage: CGImage, orientation: CGImagePropertyOrientation)

    /// Bitmaps the parser can OCR, from a document that never met the
    /// camera: the picked image itself, or up to `pageLimit` rendered pages
    /// of a picked PDF. Pass whichever the user gave you — the image wins if
    /// both arrive. Empty when nothing renders: a broken image, or a PDF
    /// that won't open (encrypted, truncated).
    ///
    /// The rendering is the fiddly part callers should not have to repeat:
    /// PDF pages come out of `mediaBox` upscaled to roughly 2400pt on the
    /// long side (small text survives OCR at that size and not much below
    /// it), and an image with no `cgImage` behind it — CIImage-backed, as
    /// drag & drop and share providers deliver — is redrawn into a bitmap
    /// rather than skipped.
    public static func pageImages(image: UIImage? = nil, pdfFilePath: URL? = nil,
                                  pageLimit: Int = 1) -> [Page] {

        var sources: [UIImage] = []

        if let image {
            sources = [image]
        }
        else if let pdfFilePath, let pdf = PDFDocument(url: pdfFilePath) {
            for index in 0 ..< min(pageLimit, pdf.pageCount) {
                guard let page = pdf.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let side = max(bounds.width, bounds.height)
                let scale = side > 0 ? max(1, 2400 / side) : 1
                sources.append(page.thumbnail(of: CGSize(width: bounds.width * scale,
                                                         height: bounds.height * scale), for: .mediaBox))
            }
        }

        return sources.compactMap { source in
            if let cg = source.cgImage {
                return (cg, cgOrientation(from: source.imageOrientation))
            }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let redrawn = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: source.size))
            }.cgImage
            return redrawn.map { ($0, .up) }   // draw() bakes the orientation in
        }
    }

    /// Answer a `DocumentValueRequest` from a picked photo or PDF — the
    /// counterpart to `DocumentScanner.presentValueScan`, for a document
    /// the user already has. Every page is parsed as a full document, so a
    /// value reads out of the field a layout labels when there is one and
    /// out of the raw text when there isn't.
    ///
    /// Pages are read in order and the search stops at the first that
    /// yields the value, so the common one-page case costs exactly one OCR
    /// pass. `completion` runs on the main queue; nil means no page carried
    /// the value (or nothing rendered at all).
    public static func readValue(image: UIImage? = nil, pdfFilePath: URL? = nil,
                                 request: DocumentValueRequest,
                                 completion: @escaping (String?) -> Void) {

        firstValue(in: pageImages(image: image, pdfFilePath: pdfFilePath, pageLimit: request.pageLimit),
                   expecting: nil,
                   yielding: request.read,
                   completion: completion)
    }

    /// Read an IBAN out of a picked photo or PDF.
    public static func readIBAN(image: UIImage? = nil, pdfFilePath: URL? = nil,
                                completion: @escaping (String?) -> Void) {

        readValue(image: image, pdfFilePath: pdfFilePath, request: .iban, completion: completion)
    }

    // MARK: - The shared page walk

    /// Parse `pages` off the main queue, stopping at the first one
    /// `yielding` turns into a value, and hand the result back on the main
    /// queue. The early exit is the point: a five-page PDF whose first page
    /// carries what was asked for costs one parse, not five.
    private static func firstValue<Value>(in pages: [Page],
                                          expecting: DocumentKind?,
                                          yielding: @escaping (ScannedDocument) -> Value?,
                                          completion: @escaping (Value?) -> Void) {

        guard !pages.isEmpty else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var found: Value?
            for page in pages {
                guard let document = try? DocumentParser.parse(image: page.cgImage,
                                                               orientation: page.orientation,
                                                               expecting: expecting) else { continue }
                if let value = yielding(document) {
                    found = value
                    break
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    static func cgOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
#endif
