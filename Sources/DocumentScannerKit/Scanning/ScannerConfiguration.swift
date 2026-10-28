//
//  ScannerConfiguration.swift
//  DocumentScannerKit
//
//  Tunables for a scanning session. Sensible defaults mean callers can pass
//  `.default` (or nothing) and get plug-and-play behavior.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ScannerConfiguration: Sendable {

    /// Whether the scanner auto-detects the document (`.auto`) or targets a
    /// caller-declared type (`.manual(_:)`). In manual mode the scanner only
    /// auto-captures when the detected type matches, and every result is tagged
    /// via `ScannedDocument.matchesExpectedType`.
    public var mode: ScanMode

    /// In auto mode, restrict auto-capture to these kinds. `nil` accepts every
    /// kind. Ignored in manual mode (the declared type governs).
    public var acceptedDocumentTypes: Set<DocumentKind>?

    /// Auto-emit the moment a valid MRZ is detected across enough frames.
    public var autoCaptureMRZ: Bool

    /// Auto-emit non-MRZ documents (cheques, ID fronts) once the classifier
    /// settles on a confident type across enough frames. The manual Capture
    /// button always remains available regardless of this setting.
    public var autoCaptureOnClassification: Bool

    /// Minimum classification confidence (0...1) required to auto-emit a
    /// non-MRZ document. Ignored by the MRZ path (check digits gate that).
    public var minimumAutoConfidence: Double

    /// Opt-in strict gate. When false (default), a steady rectangular border is
    /// enough: the scanner captures whatever document it detects and holds
    /// steady, the border turns to `steadyBorderColor` on steadiness, and the
    /// shutter is always live — the parser then fills only the fields it can
    /// validate, so eager capture never yields wrong data. When true, BOTH
    /// auto-capture and the shutter wait for the document to read *confidently*
    /// (a check-digit-valid MRZ, or a classification at/above
    /// `minimumAutoConfidence` for an accepted kind): the border stays blue and
    /// the shutter disabled until then. Ignored in capture-only mode (no OCR).
    public var autoCaptureRequiresReadable: Bool = true

    /// Content-driven auto-capture: when set, auto-capture fires only once a
    /// live frame's OCR lines satisfy this predicate (a document must still be
    /// detected and held steady — the framing gates are unchanged). It REPLACES
    /// the MRZ/classification readiness checks: use it when the capture target
    /// is a piece of CONTENT (an IBAN, a reference number) rather than a
    /// document type — a handwritten note never classifies, and a bank letter
    /// classifying confidently is still useless until the wanted value is
    /// actually readable. The manual shutter stays live regardless, so the
    /// user can always capture and let the still-photo parse decide.
    /// Runs on the video-processing queue — keep it pure and fast.
    public var autoCaptureContentGate: (@Sendable ([String]) -> Bool)?

    /// How long (seconds) the document must sit steady inside the frame before
    /// auto-capture fires — a focus-and-hold dwell so the lens settles and the
    /// scanner doesn't grab a document the instant it enters the border. The
    /// manual shutter ignores this and captures immediately. Default 1.8s.
    public var autoCaptureDwell: TimeInterval = 1.8

    /// How many consecutive frames must agree before auto-emit.
    public var votesNeeded: Int

    /// Require an actual document to be detected filling the on-screen guide
    /// before any auto-capture fires. This stops the scanner from grabbing a
    /// result the instant a few words are recognized — it waits until the whole
    /// document is inside the frame. Manual capture is unaffected.
    public var requiresDocumentInFrame: Bool

    /// Coverage the detected document must reach to count as "in frame"
    /// (0...1): the fraction of the *guide rectangle* it covers when the guide
    /// overlay is shown — the document must also sit inside the guide's
    /// boundary lines — or the fraction of the whole frame when it isn't.
    /// The default asks for a comfortable fit — small documents (ID cards)
    /// must stay outside the lens's minimum focus distance, while distant
    /// captures would starve fine print (the cheque MICR band, ID microtext)
    /// of pixels. 0.5 of the guide keeps both readable and focusable.
    public var minimumFillRatio: Double

    /// In manual mode, when a *different* known document type is detected than
    /// the one the caller declared, prompt the user to switch to it or keep
    /// scanning the chosen type. Set false to silently ignore mismatches.
    public var promptOnTypeMismatch: Bool

    /// When a known document type differs from the caller's expected type,
    /// show an action that captures and returns it as an unverified attachment.
    /// Disabled by default so typed scanning remains strict unless the host
    /// explicitly permits attachment-only capture.
    public var allowsMismatchedAttachment: Bool = false

    /// Print the raw recognized OCR lines (and parsed fields) to the console on
    /// each capture — useful for debugging what the camera actually read.
    public var logsRawText: Bool

    /// Draw the dimmed boundary guide overlay on the camera preview.
    public var showsGuideOverlay: Bool

    /// Aspect ratio (width / height) of the guide rectangle. Defaults to a wide
    /// frame suited to cheques and ID cards; set ~1.42 for passports.
    public var guideAspectRatio: Double

    /// Border style. True (default): a fixed cutout rectangle (QKMRZScanner
    /// style) — a stable viewport that never moves, the document is placed
    /// inside it and scanned. False: a live quadrilateral hugs the detected
    /// document's edges (VisionKit-style).
    public var useStaticBorder: Bool = true

    /// Fixed-border only: let the guide rectangle follow the document actually
    /// in view — the rectangle locks onto the detected document and holds
    /// steady. False (default): one static rectangle that never moves; whatever
    /// sits inside it is scanned. Ignored in dynamic-border mode.
    public var adaptsStaticBorderToDocument: Bool = false

    /// Opt in to treating a fixed guide as a strict document boundary. When
    /// enabled, a document that is too close (outside the guide) or too far
    /// away (not filling enough of it) cannot auto-capture. The default keeps
    /// existing scan modes unchanged; Passport Front opts in so its crop and
    /// MRZ always come from the visible boundary.
    public var enforcesGuideBoundary: Bool = false

    /// Show an on-screen **Dynamic / Fixed / Fixed Border** switch above the
    /// capture button that flips the border style live — a comparison aid. Off
    /// by default; the code is retained so it can be re-enabled for testing.
    public var showsBorderStyleToggle: Bool = false

#if canImport(UIKit)
    /// Dynamic-border stroke while the border is tracking the document and
    /// the hand is still settling.
    public var trackingBorderColor: UIColor = .systemBlue

    /// Dynamic-border stroke once the document is held steady — capture is
    /// imminent.
    public var steadyBorderColor: UIColor = .systemGreen
#endif

    /// Capture-only mode: no OCR or parsing runs at all. The scanner waits
    /// for the document to sit steady inside the guide, takes the still,
    /// perspective-crops it to the detected document boundaries and delivers
    /// the image via `onCapturedImage` — the original pixels, minus the
    /// background. Used for plain document capture (attachments).
    public var captureOnly: Bool = false

    /// Show the built-in manual Capture button overlay.
    public var showsCaptureButton: Bool

    /// Show the built-in Cancel button overlay.
    public var showsCancelButton: Bool

    public var captureButtonTitle: String
    public var cancelButtonTitle: String
    /// Optional contextual guidance shown above the boundary guide.
    public var helpText: String?
    public var instructionText: String

    public init(mode: ScanMode = .auto,
                acceptedDocumentTypes: Set<DocumentKind>? = nil,
                autoCaptureMRZ: Bool = true,
                autoCaptureOnClassification: Bool = true,
                minimumAutoConfidence: Double = 0.5,
                autoCaptureRequiresReadable: Bool = true,
                votesNeeded: Int = 2,
                requiresDocumentInFrame: Bool = true,
                minimumFillRatio: Double = 0.5,
                promptOnTypeMismatch: Bool = true,
                logsRawText: Bool = false,
                showsGuideOverlay: Bool = true,
                guideAspectRatio: Double = 1.58,
                showsCaptureButton: Bool = true,
                showsCancelButton: Bool = true,
                captureButtonTitle: String = "Capture",
                cancelButtonTitle: String = "Cancel",
                helpText: String? = nil,
                instructionText: String = "Fit the whole document inside the frame; it captures automatically.") {
        self.mode = mode
        self.acceptedDocumentTypes = acceptedDocumentTypes
        self.autoCaptureMRZ = autoCaptureMRZ
        self.autoCaptureOnClassification = autoCaptureOnClassification
        self.minimumAutoConfidence = minimumAutoConfidence
        self.autoCaptureRequiresReadable = autoCaptureRequiresReadable
        self.votesNeeded = votesNeeded
        self.requiresDocumentInFrame = requiresDocumentInFrame
        self.minimumFillRatio = minimumFillRatio
        self.promptOnTypeMismatch = promptOnTypeMismatch
        self.logsRawText = logsRawText
        self.showsGuideOverlay = showsGuideOverlay
        self.guideAspectRatio = guideAspectRatio
        self.showsCaptureButton = showsCaptureButton
        self.showsCancelButton = showsCancelButton
        self.captureButtonTitle = captureButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
        self.helpText = helpText
        self.instructionText = instructionText
    }

    /// Auto-detect whatever document is presented.
    public static var auto: ScannerConfiguration { .init(mode: .auto) }

    /// Target a specific, caller-declared document type.
    public static func manual(_ kind: DocumentKind) -> ScannerConfiguration {
        .init(mode: .manual(kind))
    }

    public static var `default`: ScannerConfiguration { .auto }

    /// Whether a detected kind is allowed to auto-emit under this config.
    func allowsAutoCapture(of kind: DocumentKind) -> Bool {
        if let expected = mode.expectedType { return kind == expected }
        if let accepted = acceptedDocumentTypes { return accepted.contains(kind) }
        return true
    }
}
