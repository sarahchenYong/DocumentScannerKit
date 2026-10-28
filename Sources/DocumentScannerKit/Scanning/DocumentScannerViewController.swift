//
//  DocumentScannerViewController.swift
//  DocumentScannerKit
//
//  Self-contained UIKit camera scanner. The live video stream is used only to
//  detect the document, drive the boundary guide, and decide *when* to capture.
//  The actual data extraction runs on a full-resolution still photo taken with
//  AVCapturePhotoOutput — the same quality that yields exact results on a static
//  image. This is what makes live scanning stable and accurate instead of
//  reading motion-blurred preview frames.
//
//  The consuming app must declare `NSCameraUsageDescription` in its Info.plist.
//

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit
import AVFoundation
import Vision
import ImageIO

public final class DocumentScannerViewController: UIViewController {

    /// Delivered once, when a document is captured or auto-detected.
    public var onResult: ((ScannedDocument) -> Void)?
    /// Delivered as soon as the still photo is taken and cropped to the
    /// document — before parsing begins. Present this image with your own
    /// "parsing…" indicator; `onResult` follows when extraction completes
    /// (it fires even if this controller is dismissed in between).
    public var onCapturedImage: ((UIImage) -> Void)?
    /// Capture-only mode's result: the boundary-cropped image plus the kind
    /// it should be filed under (per the user's choice on a mismatch).
    public var onCaptureOnlyResult: ((CapturedDocument) -> Void)?
    /// Delivered if the user taps Cancel (or camera access is unavailable).
    public var onCancel: (() -> Void)?

    private let configuration: ScannerConfiguration
    /// Runtime border style, seeded from the configuration. Mutable so the
    /// on-screen border-mode switch can flip it live. Three modes:
    /// • Dynamic  — `useStaticBorder=false`: the quad hugs the detected document.
    /// • Fixed    — `useStaticBorder=true, adapts=true`: a rectangle locks onto
    ///   the detected document and holds steady.
    /// • Fixed Border — `useStaticBorder=true, adapts=false`: one static
    ///   rectangle that never moves; whatever sits inside it is scanned.
    private var useStaticBorder: Bool
    private var adaptsStaticBorderToDocument: Bool

    public init(configuration: ScannerConfiguration = .default) {
        self.configuration = configuration
        // Auto slot capture supplies a single accepted kind rather than a
        // manual mode. Treat that single kind as the live expectation too, so
        // a known wrong document can be rejected before any capture occurs.
        self.expectedType = configuration.mode.expectedType
            ?? (configuration.acceptedDocumentTypes?.count == 1
                ? configuration.acceptedDocumentTypes?.first : nil)
        self.useStaticBorder = configuration.useStaticBorder
        self.adaptsStaticBorderToDocument = configuration.adaptsStaticBorderToDocument
        super.init(nibName: nil, bundle: nil)
        // Full-screen camera UI: no status bar. Capturing the appearance also
        // means hosts that hide their own status bar (nav bar at y=0) see no
        // visibility flip across presentation — the flip is what knocks a
        // presenting navigation bar out of place on dismissal.
        modalPresentationCapturesStatusBarAppearance = true
    }

    public override var prefersStatusBarHidden: Bool { true }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Capture stack
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "documentscannerkit.session")
    private let videoQueue = DispatchQueue(label: "documentscannerkit.video")
    private var preview: AVCaptureVideoPreviewLayer!
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var hasPhotoOutput = false
    private weak var videoConnection: AVCaptureConnection?
    /// Accessed only on `sessionQueue`.
    private var sessionLifecycle = ScannerSessionLifecycle()

    // Vision (reused; documentRequest aims, textRequest decides when to fire)
    private let textRequest = VNRecognizeTextRequest()
    private let documentRequest = VNDetectDocumentSegmentationRequest()

    // Shared state (touched on videoQueue + main; guarded where needed)
    private let stateLock = NSLock()
    private var latestLines: [String] = []
    private var votes: [String: Int] = [:]
    private var finished = false
    private var capturing = false
    private var documentAligned = false
    private var currentFraming = Framing.none
    private var alignedStreak = 0
    /// When the document first became aligned (0 = dwell not started). Auto
    /// capture waits `autoCaptureDwell` seconds past this before firing.
    private var alignedSince: CFAbsoluteTime = 0
    /// Last time the document was aligned — a brief loss (hand shake, one
    /// dropped detection) within `alignGrace` does NOT restart the dwell, so a
    /// shaky hold still completes instead of resetting forever.
    private var lastAlignedAt: CFAbsoluteTime = 0
    private let alignGrace: CFAbsoluteTime = 0.7
    private var backupStill: (CGImage, CGImagePropertyOrientation)?
    /// The last MRZ block that parsed check-digit-valid on a live preview
    /// frame — the fallback when the captured still's own MRZ text doesn't.
    private var lastValidMRZBlock: String?
    /// The most confident classification any live frame produced, with the
    /// lines that produced it — the fallback when the captured still's own
    /// text classifies worse (glare or motion at the shutter).
    private var bestLiveClassification: (kind: DocumentKind, confidence: Double, lines: [String])?
    /// Capture-only with an expected kind: consecutive frames whose confident
    /// classification names a DIFFERENT document, and what it looked like.
    private var captureMismatchStreak = 0
    private var captureMismatchKind: DocumentKind?
    private var captureWarningShowing = false
    /// Set only after the user explicitly chooses to attach a mismatched
    /// document. Lets that one capture pass the normal strict type gate.
    private var attachmentOnlyCaptureRequested = false
    /// The still captured as soon as a live mismatch is confirmed. It stays
    /// private until the user explicitly chooses to attach it.
    private var pendingMismatchAttachment: (image: UIImage, detected: DocumentKind, expected: DocumentKind)?
    /// What the user chose to file a mismatched capture under.
    private var captureSaveKind: DocumentKind?
    /// Set at manual-capture time when the live view disagreed with the
    /// expected kind: the still is taken first and the user decides after,
    /// with the photo already "on air".
    private var captureNeedsDecision = false
    /// Analyzed frames that actually contained text. With a declared kind the
    /// static cutout is always "aligned", so the dwell alone would fire blind;
    /// auto-capture waits until the classifier has had readable frames to judge.
    private var captureTextFrames = 0
    private let backupSemaphore = DispatchSemaphore(value: 0)
    private var backupDelegate: PhotoCaptureDelegate?
    /// The guide rectangle mapped into the video buffer's normalized
    /// (top-left-origin) coordinate space; written on main whenever layout
    /// changes, read on the video queue to test containment.
    private var guideMetadataRect: CGRect?
    private var lastAnalysis = CFAbsoluteTime(0)

    // Manual capture / mismatch
    private var pendingManualCapture = false
    private var expectedType: DocumentKind?
    private var mismatchVotes = 0
    private var mismatchAlertShowing = false
    private var mismatchSuppressed = false
    private var photoDelegate: PhotoCaptureDelegate?

    // Overlay
    private let titleLabel = PaddedLabel()
    private let instructionLabel = PaddedLabel()
    /// The camera-app-style round shutter. Enabled only while the document
    /// reads as steady + confident (green border); a tap otherwise is a no-op,
    /// so a deliberate capture can never emit data we couldn't read cleanly.
    private var shutterButton: ShutterButton?
    private var shutterLeadingConstraint: NSLayoutConstraint?
    private var shutterTopConstraint: NSLayoutConstraint?
    private weak var cancelButton: UIButton?
    /// The on-screen Dynamic/Fixed border switch (comparison aid).
    private var borderStyleToggle: UISegmentedControl?
    /// Whether the document currently reads as capture-ready (steady + a valid
    /// MRZ / confident classification, or simply steady in capture-only mode).
    /// Drives the green border and the shutter's enabled state; last value
    /// pushed to the UI is `lastReadableUI` so we only touch the main thread on
    /// a change.
    private var dataReadable = false        // guarded by stateLock
    private var lastReadableUI = false       // main thread only
    private let dimLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    /// Dynamic border: a live quadrilateral hugging the detected document.
    private let quadLayer = CAShapeLayer()
    /// Last quad corners (Vision-normalized) for the stability test.
    private var lastQuadCorners: [CGPoint]?
    /// Low-pass-filtered corners — what the border actually draws. Vision's
    /// raw quad jitters ±1% frame to frame even over a motionless document,
    /// and drawing it directly makes the border tremble.
    private var smoothedQuadCorners: [CGPoint]?
    /// Leaky average of corner motion, so a single noisy detection can't
    /// restart the steadiness clock the way a real hand movement does.
    private var quadMotion = 0.0
    /// When the detected quad last moved — steadiness is measured in time,
    /// since the border tracks every frame.
    private var quadSteadySince = CFAbsoluteTime(0)
    /// Latest raw detection quad (sensor-space, Vision-normalized), guarded by
    /// stateLock: the still-photo crop falls back to it when the still's own
    /// detection pass fails, so the delivered image is never the full frame.
    private var liveQuadSnapshot: [CGPoint]?
    /// Fixed adaptive border: the on-screen rectangle framing the *detected*
    /// document, held steady with hysteresis so it doesn't jitter frame-to-frame.
    /// It matches the document's real position/size/aspect (a small rect for a
    /// doc on another phone's screen, a big one for a physical page). Main thread.
    private var stableGuideRect: CGRect?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureVision()
        installOverlay()
        requestAccessThenConfigure()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSessionIfNeeded()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        layoutGuide()
        layoutCaptureButton()
        updateOrientation()
    }

    deinit {
        sessionQueue.async { [session, videoOutput] in
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionLifecycle.requestStart()
            self.startConfiguredSessionIfNeeded()
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionLifecycle.requestStop()
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Must be called on `sessionQueue`, after the outermost configuration
    /// transaction has committed.
    private func startConfiguredSessionIfNeeded() {
        guard sessionLifecycle.shouldStart, !session.isRunning else { return }
        session.startRunning()
    }

    // MARK: - Public capture trigger

    /// Request a manual capture — takes a still photo and returns its result.
    /// In capture-only mode with an expected kind, a live view that clearly
    /// shows a different document still captures the photo FIRST; the
    /// Replace/Update decision alert follows with the image already taken.
    public func capture() {
        guard !finished, !capturing else { return }
        // A manual shutter tap must honor the same live mismatch gate as
        // auto-capture. Do not take or emit a still once a wrong document has
        // already been identified in the preview.
        if configuration.promptOnTypeMismatch,
           let expected = expectedType,
           mismatchVotes >= configuration.votesNeeded,
           let detected = captureMismatchKind,
           !mismatchAlertShowing {
            mismatchAlertShowing = true
            DispatchQueue.main.async { [weak self] in
                self?.presentMismatchAlert(detected: detected, expected: expected)
            }
            return
        }
        if configuration.captureOnly, expectedType != nil {
            captureNeedsDecision = captureMismatchStreak >= 2
        }
        triggerCapture(manual: true)
    }

    /// The still is taken — ask what to do with a mismatched document, then
    /// deliver (or discard and resume scanning).
    private func presentCaptureDecision(image: UIImage, expected: DocumentKind) {
        mismatchAlertShowing = true
        let detected = captureMismatchKind
        let seenText = detected.map { "this looks like a \($0.rawValue)" } ?? "this looks like a different document"
        let alert = UIAlertController(
            title: "Different Document",
            message: "You selected \(expected.rawValue), but \(seenText). What would you like to do?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Replace \(expected.rawValue)", style: .default) { [weak self] _ in
            self?.mismatchAlertShowing = false
            self?.deliverCaptureOnly(image: image, kind: expected, detected: detected)
        })
        if let detected {
            alert.addAction(UIAlertAction(title: "Update \(detected.rawValue)", style: .default) { [weak self] _ in
                self?.mismatchAlertShowing = false
                self?.deliverCaptureOnly(image: image, kind: detected, detected: detected)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            // Discard the still and keep scanning. Restart the dwell so
            // auto-capture doesn't immediately re-fire on the same wrong
            // document — the user needs a beat to swap it out.
            self?.mismatchAlertShowing = false
            self?.captureNeedsDecision = false
            self?.alignedSince = 0
            self?.capturing = false
            self?.refreshAlignmentUI()
        })
        present(alert, animated: true)
    }

    /// Finish a capture-only run: stop the camera and hand out the result.
    private func deliverCaptureOnly(image: UIImage, kind: DocumentKind?, detected: DocumentKind?) {
        finishCaptureOnly()
        onCapturedImage?(image)
        onCaptureOnlyResult?(CapturedDocument(image: image, kind: kind, detectedKind: detected))
    }

    // MARK: - Camera setup

    private func requestAccessThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureSession() } else { self?.showCameraUnavailable() }
                }
            }
        default:
            showCameraUnavailable()
        }
    }

    private func configureVision() {
        // Accurate even on preview frames so the MRZ / keywords needed to decide
        // *when* to auto-capture are reliably detected. Heavy work is throttled
        // (see captureOutput) so this stays smooth.
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["en-US"]
        textRequest.minimumTextHeight = 0.02
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.sessionLifecycle.isConfigured else {
                self.startConfiguredSessionIfNeeded()
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo        // full-res stills

            // A VIRTUAL device (triple/dual-wide), not the bare wide lens: it
            // keeps the system's automatic lens switching, so when a small
            // document is held inside the wide camera's minimum focus
            // distance (up to ~20cm on Pro phones) iOS hands off to the
            // ultra-wide for macro instead of leaving the preview blurred.
            let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            guard let device,
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showCameraUnavailable() }
                return
            }
            self.session.addInput(input)

            // Documents are always near: continuous autofocus, biased to the
            // near range so the lens doesn't hunt toward the background. On a
            // virtual device, zoom factor 1.0 is the ULTRA-WIDE lens — start
            // at the first switch-over factor, which is the wide lens's 1x
            // (what the Camera app shows); the system still hands off to the
            // ultra-wide automatically for macro distances.
            if (try? device.lockForConfiguration()) != nil {
                if device.isVirtualDevice,
                   let wideZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                    device.videoZoomFactor = CGFloat(truncating: wideZoom)
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .near
                }
                device.unlockForConfiguration()
            }

            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            self.videoConnection = self.videoOutput.connection(with: .video)

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.hasPhotoOutput = true
                if #available(iOS 13.0, *) { self.photoOutput.maxPhotoQualityPrioritization = .quality }
            }

            self.session.commitConfiguration()
            self.sessionLifecycle.markConfigured()
            self.startConfiguredSessionIfNeeded()

            DispatchQueue.main.async { self.attachPreview() }
        }
    }

    private func attachPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        updateOrientation()
        layoutGuide()          // seed the guide→buffer mapping now preview exists
    }

    private func updateOrientation() {
        let io = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let orientation: AVCaptureVideoOrientation
        switch io {
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft:      orientation = .landscapeLeft
        case .landscapeRight:     orientation = .landscapeRight
        default:                  orientation = .portrait
        }
        for connection in [preview?.connection, videoConnection, photoOutput.connection(with: .video)] {
            if let c = connection, c.isVideoOrientationSupported { c.videoOrientation = orientation }
        }
    }

    // MARK: - Boundary guide

    /// Width ÷ height of the *default* fixed guide — used only before a document
    /// is detected (or for a declared type). Once the fixed border locks onto a
    /// detected document, `stableGuideRect` drives the shape instead.
    private var guideAspectRatio: Double {
        if let expected = expectedType { return Self.presetGuideAspect(for: expected) ?? expected.guideAspectRatio }
        return configuration.guideAspectRatio
    }

    /// Sensible default shapes per declared document type (before any detection).
    static func presetGuideAspect(for kind: DocumentKind) -> Double? {
        switch kind {
        case .passportFront, .passportBack, .visa, .residencePermit:
            return 1.42                       // ID-3 page — landscape
        case .emiratesIDFront, .emiratesIDBack, .nationalID, .drivingLicense:
            return 1.585                      // ID-1 card — landscape
        case .bankCheque:
            return 2.2                        // cheque leaf — wide
        case .tradeLicense:
            return 0.71                       // A4 — portrait
        case .utilityBill, .addressNote:
            return 0.71                       // A4 / letter page
        case .businessCard:
            return 1.75                       // typical business card
        case .unknown:
            return nil
        }
    }

    /// Fixed adaptive border: frame the *detected* document. Map its quad into
    /// view space, take the axis-aligned bounding box, and only move the guide
    /// when it shifts meaningfully (hysteresis) — so it snaps onto the document
    /// and holds dead still while the document doesn't move. Runs on main.
    private func updateStableGuideRect(cornersNormalized corners: [CGPoint]) {
        guard let preview, corners.count == 4 else { return }
        let pts = corners.map { c -> CGPoint in
            preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: c.x, y: 1 - c.y, width: 0, height: 0)).origin
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        let pad: CGFloat = 12
        var rect = CGRect(x: minX - pad, y: minY - pad,
                          width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
            .intersection(view.bounds)
        guard rect.width > 60, rect.height > 60 else { return }   // ignore stray tiny quads
        // Hysteresis: hold the current frame unless an edge moved > ~4% of the
        // screen. Keeps it rock-steady for a motionless document.
        if let cur = stableGuideRect {
            let tolX = view.bounds.width * 0.04, tolY = view.bounds.height * 0.04
            if abs(rect.minX - cur.minX) < tolX, abs(rect.maxX - cur.maxX) < tolX,
               abs(rect.minY - cur.minY) < tolY, abs(rect.maxY - cur.maxY) < tolY {
                return
            }
        }
        stableGuideRect = rect
        layoutGuide()
    }

    /// The quad to crop the captured still to, in the same Vision-normalized
    /// (bottom-left origin) space as `liveQuadSnapshot`. In fixed-border mode
    /// this is the on-screen guide rectangle itself, so a capture always yields
    /// exactly what sat inside the border even when Vision's document detection
    /// never fired. In dynamic mode it's the tracked document quad.
    private func currentCropQuad() -> (quad: [CGPoint]?, forced: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        if useStaticBorder, let r = guideMetadataRect {
            let border = [CGPoint(x: r.minX, y: 1 - r.minY),
                          CGPoint(x: r.maxX, y: 1 - r.minY),
                          CGPoint(x: r.maxX, y: 1 - r.maxY),
                          CGPoint(x: r.minX, y: 1 - r.maxY)]
            if expectedType != nil {
                // Typed scan: the cutout is shaped to the declared document, so
                // crop to EXACTLY the on-screen border — nothing more, nothing
                // less (e.g. a cheque's wide cutout captures the whole cheque).
                return (border, true)
            }
            // Auto scan (several possible shapes — a portrait trade licence, a
            // landscape passport…): capture the whole DETECTED document so no
            // shape is clipped by the generic cutout; fall back to the cutout
            // only when detection doesn't fire.
            return (liveQuadSnapshot ?? border, false)
        }
        return (liveQuadSnapshot, false)
    }

    private func guideRect() -> CGRect {
        // Once locked onto a detected document, the border IS that document's
        // framed rectangle.
        if useStaticBorder, adaptsStaticBorderToDocument, let r = stableGuideRect {
            return r
        }
        let bounds = view.bounds
        // The guide lives in the camera area between the top safe area and the
        // bottom control row (toggle + shutter + status), and is centered in it.
        let sideInset: CGFloat = 28
        let topLimit = view.safeAreaInsets.top + 24
        let bottomLimit = bounds.height - view.safeAreaInsets.bottom
            - (configuration.showsCaptureButton ? 190 : 60)
        let availWidth = bounds.width - sideInset * 2
        let availHeight = max(120, bottomLimit - topLimit)
        let aspect = CGFloat(max(0.3, min(4.0, guideAspectRatio)))

        if expectedType == .businessCard {
            // A business card is small and held close to the lens — filling
            // the available width like a passport or ID page makes for a
            // border far bigger than the card itself, one that can crowd the
            // capture button below. Frame it at a standard card's own
            // on-screen footprint instead, with a comfortable 40pt margin on
            // every side to line the card up in; whatever sits inside this
            // rectangle (card + margin) is what gets captured and parsed.
            let cardWidth: CGFloat = 140
            let cardHeight = cardWidth / aspect
            let pad: CGFloat = 40
            let width = min(cardWidth + pad * 2, availWidth)
            let height = min(cardHeight + pad * 2, availHeight)
            let x = (bounds.width - width) / 2
            let y = (bounds.height - height) / 2
            return CGRect(x: x, y: y, width: width, height: height)
        }

        // A clean cutout at the document's aspect: fill the width, unless that
        // would be too tall, in which case fit the height. No distortion — a
        // stable rectangle sized to the document (QKMRZScanner-style).
        var width = availWidth
        var height = width / aspect
        if height > availHeight {
            height = availHeight
            width = height * aspect
        }
        // The cheque's wide cutout sits low enough to touch the capture button;
        // trim 20pt off the top and bottom (40pt total) so it clears it.
        if expectedType == .bankCheque {
            height = max(80, height - 40)
        }
        // Center in the full screen — equal padding top and bottom — rather
        // than in the space above the controls (which pushed it too high).
        let x = (bounds.width - width) / 2
        let y = (bounds.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Keep the shutter outside the boundary without changing the guide's
    /// original size or position.
    private func layoutCaptureButton() {
        guard let shutter = shutterButton else { return }
        let rect = guideRect()
        let shutterSize = shutter.bounds.width > 0 ? shutter.bounds.width : 72
        let spacing: CGFloat = 10
        shutterLeadingConstraint?.constant = (cancelButton?.frame.midX ?? rect.maxX) - shutterSize / 2
        shutterTopConstraint?.constant = rect.maxY + spacing
    }

    private func layoutGuide() {
        guard configuration.showsGuideOverlay else { return }
        guard useStaticBorder else {
            // Dynamic border: the quad is drawn per frame and the status pill
            // self-sizes above the shutter. Just keep it placed on layout change.
            positionStatusLabel()
            return
        }
        let rect = guideRect(); let radius: CGFloat = 14
        layoutCaptureButton()
        let mask = UIBezierPath(rect: view.bounds)
        mask.append(UIBezierPath(roundedRect: rect, cornerRadius: radius))
        dimLayer.path = mask.cgPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        guideLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        guideLayer.fillColor = UIColor.clear.cgColor
        guideLayer.lineWidth = 3
        // Neutral by default; the per-frame update turns it green when the data
        // reads. (Set here only so a fresh layout isn't briefly colourless.)
        if guideLayer.strokeColor == nil {
            guideLayer.strokeColor = UIColor.white.cgColor
        }
        positionStatusLabel()

        // Map the guide into the buffer's coordinate space for the alignment
        // test on the video queue. (Aspect-fill crops the buffer; the preview
        // layer knows the mapping.)
        let meta = preview.map { $0.metadataOutputRectConverted(fromLayerRect: rect) }
        stateLock.lock(); guideMetadataRect = meta; stateLock.unlock()
    }

    /// Where the detected document sits relative to the boundary guide.
    private enum Framing { case none, outside, tooSmall, settling, aligned }

    /// Alignment means *inside the boundary lines*: the detected document must
    /// be contained by the guide (with a small tolerance) and cover enough of
    /// it — not merely occupy a share of the camera frame, which a document
    /// overflowing the guide ("fit to screen") satisfies trivially.
    private func documentFraming() -> Framing {
        // Keep existing fixed-border modes permissive. Passport Front opts
        // into strict framing below so its crop and MRZ always come from the
        // visible guide, without changing cheque, ID, or plain-capture flows.
        if useStaticBorder, !adaptsStaticBorderToDocument,
           !configuration.enforcesGuideBoundary { return .aligned }
        guard configuration.requiresDocumentInFrame else { return .aligned }
        guard let obs = documentRequest.results?.first, obs.confidence >= 0.5 else {
            if !useStaticBorder {
                lastQuadCorners = nil
                smoothedQuadCorners = nil
                quadMotion = 0
                quadSteadySince = CFAbsoluteTimeGetCurrent()
            }
            return .none
        }

        // Dynamic border: aligned = the detected document is big enough and
        // its corners have stopped moving for a beat — no fixed frame to fit.
        if !useStaticBorder {
            let now = CFAbsoluteTimeGetCurrent()
            let corners = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
            defer { lastQuadCorners = corners }

            guard let previous = lastQuadCorners else {
                quadSteadySince = now
                quadMotion = 0
                smoothedQuadCorners = corners
                return .settling                            // need a second look
            }
            let movement = zip(corners, previous)
                .map { hypot($0.x - $1.x, $0.y - $1.y) }
                .max() ?? 1

            // The drawn border chases the raw corners through a low-pass
            // filter: detection noise cancels out and the quad glides. A real
            // move (re-aiming at another spot) snaps instead of gliding.
            if movement > 0.05, let smoothed = smoothedQuadCorners,
               smoothed.count == corners.count {
                smoothedQuadCorners = corners
            } else if let smoothed = smoothedQuadCorners, smoothed.count == corners.count {
                smoothedQuadCorners = zip(smoothed, corners).map {
                    CGPoint(x: $0.x + ($1.x - $0.x) * 0.35,
                            y: $0.y + ($1.y - $0.y) * 0.35)
                }
            } else {
                smoothedQuadCorners = corners
            }

            // Keep a leaky motion average (used only for the border colour now).
            quadMotion = quadMotion * 0.8 + Double(movement) * 0.2
            if quadMotion >= 0.015 { quadSteadySince = now }

            // "Aligned" just means a document of usable size is in view — we do
            // NOT demand the corners hold perfectly still, because a shaking
            // hand never would. Accuracy comes from the readable gate (a valid
            // MRZ / confident classification) plus the still photo's own
            // autofocus; the dwell gives the hold time. The floor only rejects
            // stray tiny quads.
            let area = obs.boundingBox.width * obs.boundingBox.height
            return Double(area) >= 0.05 ? .aligned : .tooSmall
        }

        let box = obs.boundingBox
        stateLock.lock(); let guide = guideMetadataRect; stateLock.unlock()
        guard let guide, guide.width > 0, guide.height > 0 else {
            // No guide to compare against (overlay off, preview not ready):
            // fall back to requiring the document to fill enough of the frame.
            return Double(box.width * box.height) >= configuration.minimumFillRatio ? .aligned : .tooSmall
        }
        // Vision boxes have a bottom-left origin; metadata space is top-left.
        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        if configuration.enforcesGuideBoundary {
            // Detection has a little natural edge jitter, especially on glossy
            // passport covers, so tolerate a small overshoot without accepting
            // a close-up document that is materially outside the border.
            let tolerance = min(0.025, min(guide.width, guide.height) * 0.08)
            guard guide.insetBy(dx: -tolerance, dy: -tolerance).contains(rect) else {
                return .outside
            }
        }
        let overlap = rect.intersection(guide)
        guard !overlap.isNull else { return .tooSmall }
        let coverage = Double((overlap.width * overlap.height) / (guide.width * guide.height))
        return coverage >= configuration.minimumFillRatio ? .aligned : .tooSmall
    }

    /// Render the live document border. Corners arrive Vision-normalized
    /// (bottom-left origin); the preview layer maps them through its own
    /// aspect-fill geometry.
    private func drawQuad(_ corners: [CGPoint]?, readable: Bool) {
        guard let preview else { return }
        guard let corners else {
            quadLayer.path = nil
            return
        }
        let points = corners.map { corner -> CGPoint in
            let metadata = CGRect(x: corner.x, y: 1 - corner.y, width: 0, height: 0)
            return preview.layerRectConverted(fromMetadataOutputRect: metadata).origin
        }
        let path = UIBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.close()
        CATransaction.begin()
        // The low-pass filter upstream already glides the path; an implicit
        // animation on top would only add lag.
        CATransaction.setDisableActions(true)
        quadLayer.path = path.cgPath
        // Green means "readable — capturing now"; blue means "tracking, still
        // reading". The border never goes green on geometry alone.
        let color = readable ? configuration.steadyBorderColor
                             : configuration.trackingBorderColor
        quadLayer.strokeColor = color.cgColor
        quadLayer.fillColor = color.withAlphaComponent(0.12).cgColor
        CATransaction.commit()
    }

    /// The overlay text is silent by default — a clean camera. It speaks only
    /// when the user needs it to: a wrong-document warning, or a framing nudge
    /// while a document is detected but not yet usable. Steady state (tracking,
    /// readable, capturing) shows nothing; the border carries that.
    private func refreshAlignmentUI() {
        layoutGuide()
        guard !capturing else { hideStatus(); return }
        if captureWarningShowing, let expected = expectedType {
            showStatus("Please scan the \(expected.rawValue) to proceed", isError: true)
            return
        }
        switch currentFraming {
        case .outside:  showStatus("Move back — fit the document inside the frame")
        case .tooSmall: showStatus("Move closer — fill the frame with the document")
        case .none, .settling, .aligned: hideStatus()   // the border colour conveys state
        }
    }

    /// Reveal the single status line (optionally as an error). Titles stay
    /// hidden — one concise line reads better over the camera. The pill hugs
    /// its text (20pt padding, no full-width bar) and centers above the shutter.
    private func showStatus(_ text: String, isError: Bool = false) {
        titleLabel.isHidden = true
        instructionLabel.isHidden = false
        instructionLabel.textColor = isError ? .systemRed : .white
        instructionLabel.text = text
        positionStatusLabel()
    }

    private func hideStatus() {
        titleLabel.isHidden = true
        instructionLabel.isHidden = true
    }

    /// Size the status pill to its text and center it in the row *below* the
    /// capture button, along the bottom of the screen.
    private func positionStatusLabel() {
        guard !instructionLabel.isHidden else { return }
        let maxWidth = view.bounds.width - 48
        let size = instructionLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(size.width, maxWidth)
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 12
        instructionLabel.frame = CGRect(x: (view.bounds.width - width) / 2,
                                        y: bottom - size.height,
                                        width: width, height: size.height)
    }

    /// The manual shutter is always available — a reliable fallback the user
    /// can tap any time, regardless of whether auto-capture has decided the
    /// document reads. (Border colour still reflects readability.)
    private func setShutterReadable(_ readable: Bool) {
        _ = readable
    }

    // MARK: - Overlay UI

    private func autoCaptureAllowed(_ kind: DocumentKind) -> Bool {
        if let expected = expectedType { return kind == expected }
        if let accepted = configuration.acceptedDocumentTypes { return accepted.contains(kind) }
        return true
    }

    private func installOverlay() {
        if configuration.showsGuideOverlay {
            // Add both border stacks up front and just toggle visibility — the
            // on-screen Dynamic/Fixed switch can then flip modes with no
            // re-install.
            quadLayer.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
            quadLayer.strokeColor = UIColor.white.cgColor
            quadLayer.lineWidth = 3
            quadLayer.lineJoin = .round
            view.layer.addSublayer(dimLayer)
            view.layer.addSublayer(guideLayer)
            view.layer.addSublayer(quadLayer)
            applyBorderLayerVisibility()
            layoutGuide()
        }

        // Both labels start silent; refreshAlignmentUI() reveals a single line
        // only for warnings and framing nudges.
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.isHidden = true
        view.addSubview(titleLabel)

        instructionLabel.textColor = .white
        instructionLabel.font = .preferredFont(forTextStyle: .subheadline)
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center
        instructionLabel.isHidden = true
        view.addSubview(instructionLabel)

        if configuration.showsCaptureButton {
            let shutter = ShutterButton()
            shutter.translatesAutoresizingMaskIntoConstraints = false
            shutter.accessibilityLabel = configuration.captureButtonTitle
            shutter.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
            shutter.isEnabled = true          // manual capture always available
            view.addSubview(shutter)
            shutterButton = shutter
            shutterLeadingConstraint = shutter.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            shutterTopConstraint = shutter.topAnchor.constraint(equalTo: view.topAnchor)
            NSLayoutConstraint.activate([
                shutterLeadingConstraint!,
                shutterTopConstraint!,
                shutter.widthAnchor.constraint(equalToConstant: 72),
                shutter.heightAnchor.constraint(equalToConstant: 72),
            ])
        }

        if configuration.showsBorderStyleToggle {
            let toggle = UISegmentedControl(items: ["Dynamic", "Fixed", "Fixed Border"])
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.selectedSegmentIndex = currentBorderSegment
            toggle.selectedSegmentTintColor = .white
            toggle.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            toggle.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
            toggle.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
            toggle.addTarget(self, action: #selector(borderStyleChanged(_:)), for: .valueChanged)
            view.addSubview(toggle)
            borderStyleToggle = toggle
            // Sit centered, just above the shutter row.
            let bottomAnchor = shutterButton?.topAnchor ?? view.safeAreaLayoutGuide.bottomAnchor
            let bottomInset: CGFloat = shutterButton == nil ? -40 : -16
            NSLayoutConstraint.activate([
                toggle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                toggle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: bottomInset),
            ])
        }

        if configuration.showsCancelButton {
            let cancel = makeBlurButton(title: configuration.cancelButtonTitle, bold: false)
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            view.addSubview(cancel)
            cancelButton = cancel
            NSLayoutConstraint.activate([
                cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 42),
            ])
        }

        if let helpText = configuration.helpText {
            let helpLabel = makeBlurButton(title: helpText, bold: false)
            helpLabel.isUserInteractionEnabled = false
            helpLabel.titleLabel?.numberOfLines = 0
            helpLabel.titleLabel?.textAlignment = .center
            helpLabel.accessibilityLabel = helpText
            view.addSubview(helpLabel)
            NSLayoutConstraint.activate([
                helpLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                helpLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 42),
                helpLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
                helpLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -100),
            ])
        }
    }

    private func makeBlurButton(title: String, bold: Bool) -> UIButton {
        if #available(iOS 26.0, *) {
            // The real Liquid Glass material — specular highlight and the
            // press-morph animation are driven by UIKit itself through this
            // configuration; a UIVisualEffectView wrapped by hand only ever
            // reproduces the flat blur, not the "liquid" look.
            var config = UIButton.Configuration.glass()
            config.title = title
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            let font = UIFont.preferredFont(forTextStyle: bold ? .headline : .body)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = font
                return outgoing
            }
            let button = UIButton(configuration: config)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }
        // Fallback for earlier systems: a translucent blur pill.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 14
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: bold ? .headline : .body)
        button.setTitleColor(.white, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.insertSubview(blur, at: 0)
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            blur.topAnchor.constraint(equalTo: button.topAnchor),
            blur.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        return button
    }

    private func showCameraUnavailable() {
        showStatus("Camera unavailable. Grant camera access in Settings, or run on a physical device.",
                   isError: true)
    }

    @objc private func captureTapped() { capture() }
    @objc private func cancelTapped() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    /// The segment index matching the current border mode.
    private var currentBorderSegment: Int {
        if !useStaticBorder { return 0 }              // Dynamic
        return adaptsStaticBorderToDocument ? 1 : 2   // Fixed / Fixed Border
    }

    @objc private func borderStyleChanged(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 1:  setBorderStyle(useStatic: true,  adapts: true)   // Fixed: lock onto the document
        case 2:  setBorderStyle(useStatic: true,  adapts: false)  // Fixed Border: one static rectangle
        default: setBorderStyle(useStatic: false, adapts: false)  // Dynamic: hugging quad
        }
    }

    /// Switch border mode at runtime, resetting tracking state so the new mode
    /// starts clean.
    private func setBorderStyle(useStatic: Bool, adapts: Bool) {
        guard useStaticBorder != useStatic || adaptsStaticBorderToDocument != adapts else { return }
        useStaticBorder = useStatic
        adaptsStaticBorderToDocument = adapts
        // Reset tracking state so no mode inherits another's history.
        stateLock.lock()
        dataReadable = false
        stateLock.unlock()
        lastQuadCorners = nil
        smoothedQuadCorners = nil
        stableGuideRect = nil
        quadMotion = 0
        quadSteadySince = CFAbsoluteTimeGetCurrent()
        alignedStreak = 0
        votes.removeAll()
        quadLayer.path = nil
        applyBorderLayerVisibility()
        layoutGuide()
        refreshAlignmentUI()
    }

    /// Show the layer stack for the active border style, hide the other.
    private func applyBorderLayerVisibility() {
        dimLayer.isHidden = !useStaticBorder
        guideLayer.isHidden = !useStaticBorder
        quadLayer.isHidden = useStaticBorder
        if useStaticBorder { quadLayer.path = nil }
    }

    // MARK: - Capture → still photo → parse → emit

    /// Auto-capture, gated by the focus-and-hold dwell: only fires once the
    /// document has been continuously aligned for `autoCaptureDwell` seconds.
    /// (The manual shutter bypasses this and captures immediately.)
    private func autoTrigger() {
        guard alignedSince > 0,
              CFAbsoluteTimeGetCurrent() - alignedSince >= configuration.autoCaptureDwell else { return }
        triggerCapture(manual: false)
    }

    private func triggerCapture(manual: Bool) {
        stateLock.lock()
        guard !finished, !capturing else { stateLock.unlock(); return }
        capturing = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in self?.showStatus("Capturing…") }

        guard hasPhotoOutput else {          // fallback (no photo output / simulator)
            stateLock.lock(); let lines = latestLines; stateLock.unlock()
            var doc = DocumentParser.parse(recognizedLines: lines,
                                           expecting: configuration.mode.expectedType)
            doc.scannedAt = Date()
            emit(doc)
            return
        }

        let settings = AVCapturePhotoSettings()
        if #available(iOS 13.0, *) { settings.photoQualityPrioritization = .quality }
        settings.flashMode = .off        // never flash — glare washes out screens and glossy docs
        let delegate = PhotoCaptureDelegate { [weak self] cg, orientation in
            self?.handleCaptured(cg, orientation: orientation)
        }
        photoDelegate = delegate
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.settleFocusThenCapture(settings, delegate: delegate)
        }
    }

    /// One-shot autofocus at the guide centre, then wait (bounded) for the
    /// lens to stop moving before taking the still — an unsettled lens is the
    /// main source of soft captures that read fine print poorly.
    private func settleFocusThenCapture(_ settings: AVCapturePhotoSettings,
                                        delegate: PhotoCaptureDelegate) {
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
           device.isFocusModeSupported(.autoFocus),
           (try? device.lockForConfiguration()) != nil {
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            device.focusMode = .autoFocus
            device.unlockForConfiguration()
            var waited = 0.0
            while device.isAdjustingFocus, waited < 0.8 {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
        }
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        // The one-shot autofocus above LOCKS the lens once settled. The photo
        // request has latched its settings, so hand the preview back to
        // continuous autofocus — a recovery path (failed capture) must not
        // inherit a lens frozen at the wrong distance.
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
           device.isFocusModeSupported(.continuousAutoFocus),
           (try? device.lockForConfiguration()) != nil {
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }
    }

    /// OCR a captured still and classify it. Returns the kind when it
    /// confidently names a document INCOMPATIBLE with `expected`, else nil
    /// (matching, inconclusive, or unreadable all pass — capture-only stays
    /// lenient about documents the classifier can't name).
    private func confidentMismatch(in cg: CGImage, orientation: CGImagePropertyOrientation,
                                   against expected: DocumentKind) -> DocumentKind? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        let c = DocumentClassifier.classify(lines: lines, mrz: MRZParser.firstValid(in: lines))
        guard c.kind != .unknown,
              c.confidence >= configuration.minimumAutoConfidence,
              !c.kind.isCaptureCompatible(with: expected) else { return nil }
        return c.kind
    }

    private func handleCaptured(_ cg: CGImage?, orientation: CGImagePropertyOrientation) {
        defer { photoDelegate = nil }
        guard let cg else {                  // capture failed → recover with preview text
            stateLock.lock(); let lines = latestLines; stateLock.unlock()
            capturing = false
            if !lines.isEmpty {
                var doc = DocumentParser.parse(recognizedLines: lines,
                                               expecting: configuration.mode.expectedType)
                doc.scannedAt = Date()
                emit(doc)
            } else {
                DispatchQueue.main.async { [weak self] in self?.hideStatus() }
            }
            return
        }
#if !targetEnvironment(simulator)
        // The preview can miss a classification while the shutter is pressed.
        // Check the sharp still once before parsing or emitting it. A detected
        // wrong document stays in this scanner and gets the same blocking
        // alert; no result reaches the host, so nothing is dismissed/uploaded.
        if !configuration.captureOnly,
           !attachmentOnlyCaptureRequested,
           let expected = expectedType,
           let detected = confidentMismatch(in: cg, orientation: orientation, against: expected) {
            capturing = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mismatchAlertShowing = true
                self.presentMismatchAlert(detected: detected, expected: expected)
            }
            return
        }
#endif
        // Capture-only: crop the still to the detected document boundaries
        // (the plain render — original pixels, no enhancement) and hand the
        // image back. No OCR, no parsing, no backup still.
        if configuration.captureOnly {
            let needsDecision = captureNeedsDecision
            let expected = expectedType
            let detected = captureMismatchKind
            let crop = currentCropQuad()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let pair = ImageRectifier.rectifiedImages(cg, orientation: orientation,
                                                          fallbackQuad: crop.quad,
                                                          forceFallback: crop.forced)
                let image = pair.map { UIImage(cgImage: $0.plain) }
                    ?? UIImage(cgImage: cg, scale: 1, orientation: Self.uiOrientation(orientation))
                // Last line of defence for a typed scan: classify the sharp
                // still itself (full frame, not the cutout crop). Live frames
                // can miss a wrong document — motion blur while the dwell runs
                // rarely yields a valid MRZ — but the still reads cleanly; a
                // confident conflicting kind gets the Replace/Update alert
                // instead of being silently filed under the declared type.
                var stillMismatch: DocumentKind?
                if let expected, !needsDecision {
                    stillMismatch = self.confidentMismatch(in: cg, orientation: orientation,
                                                           against: expected)
                }
                DispatchQueue.main.async {
                    if let expected, needsDecision || stillMismatch != nil {
                        if let stillMismatch { self.captureMismatchKind = stillMismatch }
                        // Photo taken and held; the user decides its fate.
                        self.presentCaptureDecision(image: image, expected: expected)
                    } else {
                        self.deliverCaptureOnly(image: image, kind: expected, detected: detected)
                    }
                }
            }
            return
        }

        // A backup still, requested immediately — focus and motion vary frame
        // to frame, and a cheque whose MICR band won't decode from the first
        // still often decodes from the second.
        let backup = PhotoCaptureDelegate { [weak self] cg2, o2 in
            guard let self else { return }
            self.stateLock.lock(); self.backupStill = cg2.map { ($0, o2) }; self.stateLock.unlock()
            self.backupSemaphore.signal()
            self.backupDelegate = nil
        }
        backupDelegate = backup
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let backupSettings = AVCapturePhotoSettings()
            if #available(iOS 13.0, *) { backupSettings.photoQualityPrioritization = .balanced }
            backupSettings.flashMode = .off
            self.photoOutput.capturePhoto(with: backupSettings, delegate: backup)
        }

        // Two stages: (1) crop to the document and hand the image out right
        // away, so the host can show it while extraction runs; (2) parse and
        // deliver the result. The closures are captured strongly — a host
        // that dismisses this controller on receiving the image still gets
        // its result.
        // Automatic slot capture uses `expectedType` only as a live gate; an
        // unreadable page must still parse as `.unknown`.
        let expected = configuration.mode.expectedType
        let deliverImage = onCapturedImage
        let deliverResult = onResult
        let logsRaw = configuration.logsRawText
        stateLock.lock()
        let liveMRZBlock = lastValidMRZBlock
        let liveBest = bestLiveClassification
        stateLock.unlock()
        let crop = currentCropQuad()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pair = ImageRectifier.rectifiedImages(cg, orientation: orientation,
                                                      fallbackQuad: crop.quad,
                                                      forceFallback: crop.forced)
            DispatchQueue.main.async { [weak self] in
                deliverImage?(pair.map { UIImage(cgImage: $0.plain) }
                              ?? UIImage(cgImage: cg, scale: 1, orientation: Self.uiOrientation(orientation)))
                self?.showStatus("Reading document…")
            }
            var doc = pair.map { DocumentParser.parse(rectified: $0, original: cg,
                                                      orientation: orientation, expecting: expected) }
                ?? DocumentParser.parseFlat(image: cg, orientation: orientation, expecting: expected)
            // The legacy MRZ scanners only ever return after a live frame
            // parses a valid MRZ; match that reliability. If the still's own
            // MRZ text failed its check digits (glare or motion at the moment
            // of capture), fall back to the MRZ already validated live.
            if doc.mrz == nil, let liveMRZBlock {
                var rescued = DocumentParser.parse(
                    recognizedLines: doc.rawText + liveMRZBlock.components(separatedBy: "\n"),
                    expecting: expected)
                rescued.image = doc.image
                doc = rescued
            }
            // Same idea for label-only documents (visas, permits, ID fronts):
            // the still can read worse than the preview did — glare at the
            // shutter, small text at distance. If a live frame classified
            // more confidently than the still's text does, fold those lines
            // in and keep the better-classified parse. Cheques are exempt:
            // their fields come from image-based MICR decoding that a
            // text-only reparse would throw away.
            if doc.mrz == nil, doc.documentType != .bankCheque,
               let liveBest, liveBest.kind != .bankCheque,
               liveBest.kind != doc.documentType, liveBest.confidence > doc.confidence {
                var rescued = DocumentParser.parse(recognizedLines: doc.rawText + liveBest.lines,
                                                   expecting: expected)
                if rescued.documentType != .unknown, rescued.confidence > doc.confidence {
                    rescued.image = doc.image
                    doc = rescued
                }
            }
            doc.scannedAt = Date()
            // The cheque parsed but its band didn't decode: give the backup
            // still (if it arrived) a chance before delivering.
            if doc.documentType == .bankCheque, doc[.receiptNumber] == nil, let self {
                _ = self.backupSemaphore.wait(timeout: .now() + 2)
                self.stateLock.lock(); let backup = self.backupStill; self.stateLock.unlock()
                if let (cg2, o2) = backup {
                    doc = DocumentParser.retryingMICR(doc, with: cg2, orientation: o2)
                }
            }
            if let self {
                self.emit(doc)
            } else {                         // scanner dismissed mid-parse
                if logsRaw { Self.logRawText(doc) }
                DispatchQueue.main.async { deliverResult?(doc) }
            }
        }
    }

    private static func uiOrientation(_ exif: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch exif {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }

    /// Capture-only runs deliver an image, not a ScannedDocument: mark the
    /// session finished and stop the camera without emitting a result.
    private func finishCaptureOnly() {
        stateLock.lock()
        guard !finished else { stateLock.unlock(); return }
        finished = true
        stateLock.unlock()
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func emit(_ doc: ScannedDocument) {
#if !targetEnvironment(simulator)
        // The still was not classifiable as the declared slot document. Keep
        // the camera open and surface the mismatch here, before the host can
        // dismiss the scanner and show its generic unreadable-document alert.
        if !configuration.captureOnly,
           !configuration.allowsMismatchedAttachment,
           !attachmentOnlyCaptureRequested,
           let expected = expectedType,
           doc.documentType == .unknown {
            capturing = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mismatchAlertShowing = true
                self.presentMismatchAlert(detected: .unknown, expected: expected)
            }
            return
        }
#endif
        stateLock.lock()
        guard !finished else { stateLock.unlock(); return }
        finished = true
        stateLock.unlock()
        if configuration.logsRawText { Self.logRawText(doc) }
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
        DispatchQueue.main.async { [weak self] in self?.onResult?(doc) }
    }

    static func logRawText(_ doc: ScannedDocument) {
        print("===== DocumentScannerKit — RAW SCANNED TEXT (\(doc.documentType.rawValue)) =====")
        for (i, line) in doc.rawText.enumerated() { print(String(format: "[%02d] %@", i, line)) }
        print("----- SIGNALS -----")
        for s in doc.classificationSignals { print(s) }
        print("----- PARSED FIELDS -----")
        for f in doc.fields { print("\(f.label): \(f.value)") }
        print("=========================================================")
    }

    // MARK: - Manual-mode type mismatch

    private func maybePromptMismatch(lines: [String]) {
        guard configuration.promptOnTypeMismatch, let expected = expectedType,
              !mismatchAlertShowing, !mismatchSuppressed else { return }
        let c = DocumentClassifier.classify(lines: lines, mrz: MRZParser.firstValid(in: lines))
        guard c.kind != .unknown, c.confidence >= configuration.minimumAutoConfidence else { return }
        if c.kind.isCaptureCompatible(with: expected) {
            mismatchVotes = 0
            mismatchSuppressed = false
            return
        }
        mismatchVotes += 1
        captureMismatchKind = c.kind
        guard mismatchVotes >= configuration.votesNeeded else { return }
        mismatchAlertShowing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.configuration.allowsMismatchedAttachment {
                self.captureMismatchAttachmentCandidate(detected: c.kind, expected: expected)
            } else {
                self.presentMismatchAlert(detected: c.kind, expected: expected)
            }
        }
    }

    /// Freeze the document that raised the live mismatch before presenting an
    /// attachment option. This prevents a later camera movement from changing
    /// what "Attach Document Only" saves.
    private func captureMismatchAttachmentCandidate(detected: DocumentKind, expected: DocumentKind) {
        stateLock.lock()
        guard !finished, !capturing else { stateLock.unlock(); return }
        capturing = true
        stateLock.unlock()

        showStatus("Capturing…")
        guard hasPhotoOutput else {
            capturing = false
            mismatchAlertShowing = false
            hideStatus()
            return
        }

        let settings = AVCapturePhotoSettings()
        if #available(iOS 13.0, *) { settings.photoQualityPrioritization = .quality }
        settings.flashMode = .off
        let delegate = PhotoCaptureDelegate { [weak self] cg, orientation in
            self?.handleMismatchAttachmentCandidate(cg, orientation: orientation,
                                                    detected: detected, expected: expected)
        }
        photoDelegate = delegate
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.settleFocusThenCapture(settings, delegate: delegate)
        }
    }

    private func handleMismatchAttachmentCandidate(_ cg: CGImage?, orientation: CGImagePropertyOrientation,
                                                   detected: DocumentKind, expected: DocumentKind) {
        defer { photoDelegate = nil }
        guard let cg else {
            DispatchQueue.main.async { [weak self] in
                self?.capturing = false
                self?.mismatchAlertShowing = false
                self?.hideStatus()
            }
            return
        }

        let crop = currentCropQuad()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let pair = ImageRectifier.rectifiedImages(cg, orientation: orientation,
                                                      fallbackQuad: crop.quad,
                                                      forceFallback: crop.forced)
            let image = pair.map { UIImage(cgImage: $0.plain) }
                ?? UIImage(cgImage: cg, scale: 1, orientation: Self.uiOrientation(orientation))
            DispatchQueue.main.async {
                self.capturing = false
                self.hideStatus()
                self.pendingMismatchAttachment = (image, detected, expected)
                self.presentMismatchAlert(detected: detected, expected: expected)
            }
        }
    }

    private func presentMismatchAlert(detected: DocumentKind, expected: DocumentKind) {
#if !targetEnvironment(simulator)
        let alert = UIAlertController(
            title: "Different Document",
            message: "Identified a different document. Please scan the \(expected.rawValue).",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok", style: .default) { [weak self] _ in
            // No result was emitted and the capture session was never stopped.
            // Suppress this same document until the user brings the selected
            // type into frame, then allow a new mismatch warning if needed.
            self?.pendingMismatchAttachment = nil
            self?.mismatchVotes = 0
            self?.mismatchAlertShowing = false
            self?.mismatchSuppressed = true
            self?.refreshAlignmentUI()
        })
        if configuration.allowsMismatchedAttachment {
            alert.addAction(UIAlertAction(title: "Attach Document Only", style: .default) { [weak self] _ in
                guard let self else { return }
                self.mismatchVotes = 0
                self.mismatchAlertShowing = false
                if let attachment = self.pendingMismatchAttachment {
                    self.pendingMismatchAttachment = nil
                    var document = ScannedDocument(documentType: attachment.detected,
                                                   confidence: 1,
                                                   classificationSignals: ["Attached after type mismatch"],
                                                   expectedType: attachment.expected)
                    document.image = attachment.image.jpegData(compressionQuality: 0.95)
                    self.emit(document)
                    return
                }
                self.attachmentOnlyCaptureRequested = true
                self.triggerCapture(manual: true)
            })
        }
        present(alert, animated: true)
        return
#else
        let alert = UIAlertController(
            title: "Different Document",
            message: "You're scanning a \(detected.rawValue), but you chose \(expected.rawValue). Switch, or scan the \(expected.rawValue)?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Switch to \(detected.rawValue)", style: .default) { [weak self] _ in
            self?.expectedType = detected
            self?.votes.removeAll(); self?.mismatchVotes = 0; self?.mismatchAlertShowing = false
            self?.layoutGuide()
            self?.hideStatus()
        })
        alert.addAction(UIAlertAction(title: "Keep \(expected.rawValue)", style: .cancel) { [weak self] _ in
            self?.mismatchVotes = 0; self?.mismatchAlertShowing = false; self?.mismatchSuppressed = true
        })
        present(alert, animated: true)
#endif
    }
}

// MARK: - Video frame analysis (detect + decide when to capture)

extension DocumentScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        stateLock.lock(); let busy = finished || capturing; stateLock.unlock()
        guard !busy, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // Document-edge detection and the live border run on EVERY frame —
        // the segmentation model is light, and a border that lags behind the
        // document reads as inaccurate. Heavy text recognition stays
        // throttled below.
        try? handler.perform([documentRequest])

        let framing = documentFraming()
        stateLock.lock()
        liveQuadSnapshot = (documentRequest.results?.first).map {
            [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft]
        }
        stateLock.unlock()
        let aligned = framing == .aligned
        alignedStreak = aligned ? alignedStreak + 1 : 0
        // The auto-capture dwell counts from `alignedSince`. A brief loss of
        // alignment (hand shake, a dropped detection) within `alignGrace` is
        // tolerated — the dwell keeps running — so a shaky hold still completes.
        let nowTS = CFAbsoluteTimeGetCurrent()
        if aligned {
            if alignedSince == 0 { alignedSince = nowTS }
            lastAlignedAt = nowTS
        } else if nowTS - lastAlignedAt > alignGrace {
            alignedSince = 0
        }
        // Border/shutter go "ready" (green + tappable) only when the document
        // is BOTH steady and readable; losing alignment drops readability at
        // once so a moved document never lingers green.
        if !aligned { stateLock.lock(); dataReadable = false; stateLock.unlock() }
        stateLock.lock(); let readable = aligned && dataReadable; stateLock.unlock()
        let corners = (!useStaticBorder && documentRequest.results?.first != nil)
            ? smoothedQuadCorners : nil
        // Fixed adaptive border: the detected document's quad, to frame it.
        let staticCorners: [CGPoint]? = (useStaticBorder && adaptsStaticBorderToDocument
                                         && configuration.showsGuideOverlay)
            ? (documentRequest.results?.first).map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }
            : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.useStaticBorder {
                if let staticCorners { self.updateStableGuideRect(cornersNormalized: staticCorners) }
                // Highlight the fixed cutout green the moment the data reads.
                if self.configuration.showsGuideOverlay {
                    self.guideLayer.strokeColor = (readable ? self.configuration.steadyBorderColor
                                                            : UIColor.white).cgColor
                }
            } else if self.configuration.showsGuideOverlay {
                self.drawQuad(corners, readable: readable)
            }
            self.setShutterReadable(readable)
        }

        // Throttle the heavy work to ~6 fps — smooth, cool, enough to decide.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysis >= 0.15 else {
            if framing != currentFraming {
                currentFraming = framing
                documentAligned = aligned
                DispatchQueue.main.async { [weak self] in self?.refreshAlignmentUI() }
            }
            return
        }
        lastAnalysis = now
        if !(configuration.captureOnly && expectedType == nil) {
            // Capture-only without an expected kind never needs text.
            try? handler.perform([textRequest])
        }

        if framing != currentFraming {
            currentFraming = framing
            documentAligned = aligned
            if !aligned { mismatchVotes = 0; mismatchSuppressed = false }
            DispatchQueue.main.async { [weak self] in self?.refreshAlignmentUI() }
        }

        // Auto-capture needs the document in frame. A momentary loss of
        // alignment (hand shake) within the grace window is tolerated: we skip
        // this frame but keep the accumulated votes and running dwell, so a
        // shaky hold still completes instead of resetting every jitter.
        if configuration.requiresDocumentInFrame {
            if !aligned {
                if nowTS - lastAlignedAt > alignGrace {
                    votes.removeAll(keepingCapacity: true)
                    stateLock.lock(); dataReadable = false; stateLock.unlock()
                }
                return
            }
            if useStaticBorder {
                guard alignedStreak >= 3 else { return }
            }
        }

        // Capture-only: a document held steady inside the guide is the whole
        // trigger — no OCR. With an expected kind, frames confidently classified
        // as a DIFFERENT document block capture and raise the red warning;
        // matching or inconclusive frames clear it.
        if configuration.captureOnly {
            guard !mismatchAlertShowing else { return }
            var warn = false
            if let expected = expectedType {
                let lines = (textRequest.results ?? [])
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                    .compactMap { $0.topCandidates(1).first?.string }
                if !lines.isEmpty { captureTextFrames += 1 }
                let c = DocumentClassifier.classify(lines: lines, mrz: MRZParser.firstValid(in: lines))
                if c.kind != .unknown, c.confidence >= configuration.minimumAutoConfidence {
                    if c.kind.isCaptureCompatible(with: expected) {
                        captureMismatchStreak = 0
                    } else {
                        captureMismatchStreak += 1
                        captureMismatchKind = c.kind
                    }
                }
                warn = captureMismatchStreak >= 2
                if warn != captureWarningShowing {
                    captureWarningShowing = warn
                    DispatchQueue.main.async { [weak self] in self?.refreshAlignmentUI() }
                }
            }
            // Steady (and not a conflicting document) is "readable" here.
            stateLock.lock(); dataReadable = aligned && !warn; stateLock.unlock()
            if warn { return }
            let steadyEnough = useStaticBorder ? alignedStreak >= 3 : true
            // Typed scan: never fire before at least two frames carried text —
            // the mismatch check above needs readable frames to have had a say.
            let informed = expectedType == nil || captureTextFrames >= 2
            if aligned, steadyEnough, informed { autoTrigger() }
            return
        }
        guard !mismatchAlertShowing else { return }

        let lines = (textRequest.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        stateLock.lock(); latestLines = lines; stateLock.unlock()

        // Remember the best-classified live frame; the still-photo parse
        // falls back to these lines when its own text reads worse.
        let liveC = DocumentClassifier.classify(lines: lines, mrz: MRZParser.firstValid(in: lines))
        if liveC.kind != .unknown {
            stateLock.lock()
            if liveC.confidence >= (bestLiveClassification?.confidence ?? configuration.minimumAutoConfidence) {
                bestLiveClassification = (liveC.kind, liveC.confidence, lines)
            }
            stateLock.unlock()
        }

        maybePromptMismatch(lines: lines)

        // Always remember a check-digit-valid MRZ from the live preview: the
        // still-photo parse falls back to it when the shutter frame reads worse.
        if configuration.autoCaptureMRZ {
            for block in MRZParser.candidateBlocks(lines) where MRZParser.parse(block) != nil {
                stateLock.lock(); lastValidMRZBlock = block; stateLock.unlock()
                break
            }
        }

        // Strict mode (opt-in): only capture once the data itself reads
        // confidently — a valid MRZ or a confident classification. The border
        // stays blue and the shutter disabled until then.
        if configuration.autoCaptureRequiresReadable {
            var readableNow = false
            defer { stateLock.lock(); dataReadable = readableNow; stateLock.unlock() }

            // A content gate owns readiness outright: the framing gates above
            // already required a real document in the frame, and capture fires
            // only when the caller's wanted content actually reads in the live
            // text — never on a bare classification (a cheque is not "ready"
            // until its IBAN is legible), and never on empty space.
            if let gate = configuration.autoCaptureContentGate {
                guard gate(lines) else { return }
                readableNow = true
                votes["content", default: 0] += 1
                if votes["content"]! >= configuration.votesNeeded { autoTrigger() }
                return
            }

            if configuration.autoCaptureMRZ {
                for block in MRZParser.candidateBlocks(lines) where MRZParser.parse(block) != nil {
                    let mrz = MRZParser.firstValid(in: lines)
                    let kind = DocumentClassifier.classify(lines: lines, mrz: mrz).kind
                    guard autoCaptureAllowed(kind) else { return }
                    readableNow = true
                    votes[block, default: 0] += 1
                    // A check-digit-valid MRZ is proof — capture at once, no
                    // dwell (QKMRZScanner-fast). The check digits are the gate.
                    if votes[block]! >= configuration.votesNeeded { triggerCapture(manual: false) }
                    return
                }
            }
            if configuration.autoCaptureOnClassification {
                let c = DocumentClassifier.classify(lines: lines, mrz: nil)
                if let expected = expectedType {
                    // Auto-capture ONLY on a POSITIVE match for the declared type
                    // — never on `.unknown`. A wall, tissue box or bench reads as
                    // `.unknown`; previously that was treated as "trust the
                    // caller" and captured, which made a no-MRZ type like a cheque
                    // fire on anything. The document's own classifier is strict
                    // (a cheque needs a MICR line / "or order" / IBAN, which those
                    // objects never have), and the vote + dwell debounce the rest.
                    // The manual shutter handles whatever can't be auto-named.
                    guard c.kind.isCaptureCompatible(with: expected) else { return }
                    readableNow = true
                    votes["steady", default: 0] += 1
                    if votes["steady"]! >= configuration.votesNeeded { autoTrigger() }
                } else {
                    guard c.kind != .unknown, c.confidence >= configuration.minimumAutoConfidence,
                          autoCaptureAllowed(c.kind) else { return }
                    readableNow = true
                    let key = "cls:\(c.kind.rawValue)"
                    votes[key, default: 0] += 1
                    if votes[key]! >= configuration.votesNeeded { autoTrigger() }
                }
            }
            return
        }

        // Default: a steady rectangular border IS the trigger. We're here only
        // because a real document was detected (segmentation) and held steady
        // (see documentFraming / the aligned gate above), so capture it and let
        // the parser extract whatever it can validate — the image comes out
        // right regardless of whether the text classifies. The border is green
        // (steady) and the shutter is always live as a manual override.
        // A content gate binds even in eager mode: steady framing alone must
        // not capture when the caller is waiting for specific content.
        if let gate = configuration.autoCaptureContentGate {
            let ready = gate(lines)
            stateLock.lock(); dataReadable = aligned && ready; stateLock.unlock()
            guard ready else { return }
            votes["content", default: 0] += 1
            if votes["content"]! >= configuration.votesNeeded { autoTrigger() }
            return
        }
        stateLock.lock(); dataReadable = aligned; stateLock.unlock()
        if configuration.autoCaptureMRZ || configuration.autoCaptureOnClassification {
            votes["steady", default: 0] += 1
            if votes["steady"]! >= configuration.votesNeeded { autoTrigger() }
        }
    }
}

/// A label with comfortable padding on a translucent rounded backdrop, so
/// overlay text reads cleanly over any camera content.
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 10
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right,
                                              height: size.height))
        return CGSize(width: inner.width + insets.left + insets.right,
                      height: inner.height + insets.top + insets.bottom)
    }
}

/// The iOS Camera-app shutter: a solid white disc inside a thin white ring.
/// It dims when disabled (the block-until-readable state) and gives a quick
/// scale-down on press.
final class ShutterButton: UIButton {
    private let ring = CAShapeLayer()
    private let core = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.cgColor
        layer.addSublayer(ring)
        core.fillColor = UIColor.white.cgColor
        layer.addSublayer(core)
        accessibilityTraits = .button
        // A subtle shadow keeps the white shutter legible over bright documents.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        core.frame = bounds
        ring.lineWidth = 4
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
        core.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 9, dy: 9)).cgPath
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1.0 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet {
            let scale: CGFloat = isHighlighted ? 0.88 : 1.0
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            core.transform = CATransform3DMakeScale(scale, scale, 1)
            CATransaction.commit()
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }
}

// MARK: - Photo capture delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (CGImage?, CGImagePropertyOrientation) -> Void
    init(completion: @escaping (CGImage?, CGImagePropertyOrientation) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            completion(nil, .up); return
        }
        let raw = (photo.metadata[String(kCGImagePropertyOrientation)] as? NSNumber)?.uint32Value ?? 1
        completion(cg, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }
}
#endif
