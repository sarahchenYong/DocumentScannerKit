//
//  DocumentScanner.swift
//  DocumentScannerKit
//
//  The one-call UIKit facade. Present the scanner from any view controller and
//  get the result back via a closure or `async`.
//
//      // Closure
//      DocumentScanner.present(from: self) { result in
//          print(result?.jsonString ?? "cancelled")
//      }
//
//      // async/await
//      if let doc = await DocumentScanner.scan(from: self) {
//          print(doc.fullName ?? "")
//      }
//

#if canImport(UIKit) && canImport(AVFoundation)
import UIKit

/// The outcome of a capture-only scan.
public struct CapturedDocument {
    /// The still, perspective-cropped to the detected document boundaries.
    public let image: UIImage
    /// The kind this capture should be filed under: the expected kind, or —
    /// when the user chose "Update <detected>" on a mismatch — that kind.
    /// Nil when no kind was expected.
    public let kind: DocumentKind?
    /// The live classification's last confident sighting of a DIFFERENT
    /// document, if any.
    public let detectedKind: DocumentKind?
}


@MainActor
public enum DocumentScanner {

    /// Present the scanner modally. `completion` receives the parsed document,
    /// or `nil` if the user cancelled. The scanner is dismissed automatically.
    /// Pass `onCapturedImage` to receive the cropped still the moment it is
    /// taken — the scanner dismisses right away and the host can show the
    /// image with its own progress UI while `completion` is still parsing.
    public static func present(from presenter: UIViewController,
                               configuration: ScannerConfiguration = .default,
                               onCapturedImage: ((UIImage) -> Void)? = nil,
                               completion: @escaping (ScannedDocument?) -> Void) {
        let scanner = DocumentScannerViewController(configuration: configuration)
        // Over-full-screen keeps the presenting hierarchy (and its navigation
        // bar) in place — a .fullScreen modal removes it, and the restore can
        // leave the presenter's navigation bar broken.
        scanner.modalPresentationStyle = .overFullScreen
        let restoreBars = navigationBarRestorer(for: presenter)

        // The closures live ON the scanner — capture it weakly, or the
        // instance (and its capture session) leaks and lingers into the next
        // scan. UIKit's presentation retains it while it's on screen.
        var dismissed = false
        func finish(_ scanner: DocumentScannerViewController?, _ result: ScannedDocument?) {
            if dismissed || scanner?.presentingViewController == nil { restoreBars(); completion(result) }
            else { dismissed = true; scanner?.dismiss(animated: true) { restoreBars(); completion(result) } }
        }
        scanner.onResult = { [weak scanner] in finish(scanner, $0) }
        scanner.onCancel = { [weak scanner] in finish(scanner, nil) }
        if let onCapturedImage {
            scanner.onCapturedImage = { [weak scanner] image in
                onCapturedImage(image)
                dismissed = true
                scanner?.dismiss(animated: true) { restoreBars() }
            }
        }
        presenter.present(scanner, animated: true)
    }

    /// Snapshot the presenter's navigation-bar visibility and hand back a
    /// restorer: if anything about the modal round trip knocked the bar out
    /// of its previous state, put it back. A no-op when nothing changed.
    private static func navigationBarRestorer(for presenter: UIViewController) -> () -> Void {
        weak var navController = presenter.navigationController
        let barWasHidden = navController?.isNavigationBarHidden
        return {
            guard let navController, let barWasHidden,
                  navController.isNavigationBarHidden != barWasHidden else { return }
            navController.setNavigationBarHidden(barWasHidden, animated: false)
        }
    }

    /// Present a capture-only scanner: it waits for the document to sit
    /// steady inside the guide, takes the still, perspective-crops it to the
    /// detected boundaries and returns the image — the original scanned
    /// pixels minus the background. No parsing runs. `completion` receives
    /// nil when the user cancels. The scanner dismisses itself.
    ///
    /// Pass `expecting` to bind the capture to one document kind (e.g. the
    /// slot the user picked — see `DocumentKind(slotName:)`): the guide takes
    /// that document's shape, frames confidently showing a DIFFERENT document
    /// raise a red warning in the camera view and block auto-capture, and a
    /// mismatched manual capture asks "Add Anyway / Choose Different" first.
    public static func presentCapture(from presenter: UIViewController,
                                      expecting: DocumentKind? = nil,
                                      guideAspectRatio: Double = 1.5,
                                      instructionText: String? = nil,
                                      completion: @escaping (CapturedDocument?) -> Void) {
        var config = ScannerConfiguration()
        config.captureOnly = true
        if let expecting {
            config.mode = .manual(expecting)     // guide shape + expected kind
        } else {
            config.guideAspectRatio = guideAspectRatio
        }
        config.instructionText = instructionText
            ?? expecting.map { "Position the \($0.rawValue) inside the frame" }
            ?? "Position the document inside the frame"

        let scanner = DocumentScannerViewController(configuration: config)
        scanner.modalPresentationStyle = .overFullScreen
        let restoreBars = navigationBarRestorer(for: presenter)

        func finish(_ scanner: DocumentScannerViewController?, _ captured: CapturedDocument?) {
            if let scanner, scanner.presentingViewController != nil {
                scanner.dismiss(animated: true) { restoreBars(); completion(captured) }
            } else {
                restoreBars()
                completion(captured)
            }
        }
        scanner.onCaptureOnlyResult = { [weak scanner] in finish(scanner, $0) }
        scanner.onCancel = { [weak scanner] in finish(scanner, nil) }
        presenter.present(scanner, animated: true)
    }

    /// Present the scanner to read ONE value — see `DocumentValueRequest` —
    /// off whatever page the user points it at, rather than to classify and
    /// return a whole document.
    ///
    /// Auto-capture is content-gated by the request: the shutter fires only
    /// when the value is actually readable in the live text, never on empty
    /// space and not on a mere classification whose value hasn't resolved
    /// yet. The manual shutter stays live as the fallback for a page that
    /// won't read cleanly — a manual capture is exactly what `.notFound`
    /// reports on.
    ///
    /// `DocumentReader.readValue` answers the same request for a document
    /// the user already has, and `DocumentSourceMenu` offers camera, Files
    /// and Photos as three interchangeable sources for one field.
    public static func presentValueScan(from presenter: UIViewController,
                                        request: DocumentValueRequest,
                                        completion: @escaping (ValueScanOutcome) -> Void) {
        var config = ScannerConfiguration(mode: .auto)
        config.autoCaptureContentGate = request.liveGate
        config.instructionText = request.instruction
        config.guideAspectRatio = request.guideAspectRatio

        present(from: presenter, configuration: config) { document in
            guard let document else {
                completion(.cancelled)
                return
            }
            guard let value = request.read(document) else {
                completion(.notFound)
                return
            }
            completion(.found(value))
        }
    }

    /// Present the scanner to read an IBAN off a cheque, a bank letter, a
    /// statement, or a number written on plain paper.
    public static func presentIBANScan(from presenter: UIViewController,
                                       completion: @escaping (ValueScanOutcome) -> Void) {
        presentValueScan(from: presenter, request: .iban, completion: completion)
    }

    /// Convenience: present in a given mode (`.auto` or `.manual(_:)`).
    public static func present(from presenter: UIViewController,
                               mode: ScanMode,
                               completion: @escaping (ScannedDocument?) -> Void) {
        present(from: presenter, configuration: ScannerConfiguration(mode: mode), completion: completion)
    }

    /// async/await variant of `present(from:configuration:completion:)`.
    public static func scan(from presenter: UIViewController,
                            configuration: ScannerConfiguration = .default) async -> ScannedDocument? {
        await withCheckedContinuation { continuation in
            present(from: presenter, configuration: configuration) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// async/await variant in a given mode.
    public static func scan(from presenter: UIViewController,
                            mode: ScanMode) async -> ScannedDocument? {
        await scan(from: presenter, configuration: ScannerConfiguration(mode: mode))
    }
}
#endif
