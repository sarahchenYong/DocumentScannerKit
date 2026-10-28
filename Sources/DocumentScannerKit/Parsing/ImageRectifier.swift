//
//  ImageRectifier.swift
//  DocumentScannerKit
//
//  Perspective-corrects and crops an image to just the document before OCR.
//  Angled, distant photos are the main reason handwriting and small print read
//  poorly; deskewing to a flat, tightly-cropped rectangle makes the text larger
//  and axis-aligned, which materially improves Vision's recognition.
//

#if canImport(Vision) && canImport(CoreImage)
import Vision
import CoreImage
import CoreGraphics

enum ImageRectifier {

    /// Detect the document quad and return the flattened, cropped image in two
    /// renders: `plain` (best for printed text — numbers, branch) and `enhanced`
    /// (grayscale/contrast/sharpen — best for faint handwriting). OCRing both
    /// and merging gives the highest recall. Returns nil when no confident
    /// document rectangle is found (caller should fall back to the original).
    ///
    /// `fallbackQuad` — the quad a live preview was tracking, in sensor-space
    /// (.up) Vision-normalized coordinates — is used when the still's own
    /// detection fails (glare or motion at the shutter), so a scan whose
    /// border was locked on screen always crops to that border.
    /// `forceFallback` — skip the still's own detection and crop straight to
    /// `fallbackQuad`. Used for the fixed guide border: the region the user
    /// framed is exactly what gets cropped and parsed, regardless of whether
    /// Vision would have found a (possibly wrong) rectangle on the still.
    static func rectifiedImages(_ cg: CGImage,
                                orientation: CGImagePropertyOrientation,
                                fallbackQuad: [CGPoint]? = nil,
                                forceFallback: Bool = false) -> (plain: CGImage, enhanced: CGImage)? {
        // Corners in the oriented image's normalized space: TL, TR, BR, BL.
        var corners: [CGPoint]? = nil
        if !(forceFallback && fallbackQuad != nil) {
            let request = VNDetectDocumentSegmentationRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([request])
            if let quad = request.results?.first, quad.confidence >= 0.5 {
                corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            }
        }
        if corners == nil, let fallbackQuad, fallbackQuad.count == 4 {
            // Map the live/guide quad into the oriented space. A forced guide
            // crop is taken EXACTLY (factor 1.0) — the image must equal what sat
            // inside the border. A live-quad fallback gets a small outset since
            // the photo's field of view differs slightly from the video stream's
            // and clipping a document edge costs data.
            let factor: CGFloat = forceFallback ? 1.0 : 1.04
            corners = outset(orderedCorners(fallbackQuad.map { rotated($0, by: orientation) }),
                             by: factor)
        }
        guard let corners else { return nil }

        // Work in the oriented image's coordinate space (bottom-left origin,
        // matching Vision's normalized points).
        let image = CIImage(cgImage: cg).oriented(orientation)
        let w = image.extent.width, h = image.extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(point(corners[0]), forKey: "inputTopLeft")
        filter.setValue(point(corners[1]), forKey: "inputTopRight")
        filter.setValue(point(corners[3]), forKey: "inputBottomLeft")
        filter.setValue(point(corners[2]), forKey: "inputBottomRight")
        guard let corrected = filter.outputImage, !corrected.extent.isInfinite, !corrected.extent.isEmpty else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        // Plain pass stays native resolution — sharpest for printed text
        // (numbers, branch, date). Enhanced pass is upscaled + grayscale/contrast
        // for faint handwriting.
        guard let plain = context.createCGImage(corrected, from: corrected.extent) else { return nil }
        let enhancedCI = enhance(upscale(corrected))
        let enhanced = context.createCGImage(enhancedCI, from: enhancedCI.extent) ?? plain
        return (plain, enhanced)
    }

    /// Map a Vision-normalized point (bottom-left origin) from the sensor
    /// (.up) space into the space of the image oriented by `orientation`.
    private static func rotated(_ p: CGPoint, by orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .up, .upMirrored:       return p
        case .down, .downMirrored:   return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .right, .rightMirrored: return CGPoint(x: p.y, y: 1 - p.x)
        case .left, .leftMirrored:   return CGPoint(x: 1 - p.y, y: p.x)
        @unknown default:            return p
        }
    }

    /// Reassign corner roles after rotation — TL, TR, BR, BL in a space where
    /// y grows upward — so the rectified output comes out upright.
    private static func orderedCorners(_ points: [CGPoint]) -> [CGPoint] {
        let byY = points.sorted { $0.y > $1.y }
        let top = byY.prefix(2).sorted { $0.x < $1.x }
        let bottom = byY.suffix(2).sorted { $0.x < $1.x }
        return [top[0], top[1], bottom[1], bottom[0]]
    }

    /// Scale the quad about its centroid, clamped to the unit square.
    private static func outset(_ points: [CGPoint], by factor: CGFloat) -> [CGPoint] {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return points.map {
            CGPoint(x: min(1, max(0, cx + ($0.x - cx) * factor)),
                    y: min(1, max(0, cy + ($0.y - cy) * factor)))
        }
    }

    /// Upscale so the shorter side is at least ~1600px (Vision reads larger text
    /// better); never downscale.
    private static func upscale(_ image: CIImage) -> CIImage {
        let shortSide = min(image.extent.width, image.extent.height)
        guard shortSide > 0, shortSide < 1600, let f = CIFilter(name: "CILanczosScaleTransform") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(min(3.0, 1600 / shortSide), forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? image
    }

    /// Grayscale + contrast + unsharp so faint handwriting stands out.
    private static func enhance(_ image: CIImage) -> CIImage {
        var result = image
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(result, forKey: kCIInputImageKey)
            f.setValue(1.15, forKey: kCIInputContrastKey)
            f.setValue(0.0, forKey: kCIInputSaturationKey)
            if let out = f.outputImage { result = out }
        }
        if let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(result, forKey: kCIInputImageKey)
            f.setValue(2.0, forKey: kCIInputRadiusKey)
            f.setValue(0.8, forKey: kCIInputIntensityKey)
            if let out = f.outputImage { result = out }
        }
        return result.cropped(to: image.extent)
    }
}
#endif
