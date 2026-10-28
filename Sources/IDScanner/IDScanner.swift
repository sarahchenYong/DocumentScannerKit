import DocumentScannerKit
import UIKit

/// Protected identity-document scanner facade. The camera, OCR, MRZ and
/// parsing implementation remains inside the binary framework.
@MainActor
public enum IDScanner {
    public static func present(from presenter: UIViewController,
                               configuration: ScannerConfiguration = .default,
                               completion: @escaping (ScannedDocument?) -> Void) {
        DocumentScanner.present(from: presenter,
                                configuration: configuration,
                                completion: completion)
    }

    public static func presentCapture(from presenter: UIViewController,
                                      expecting: DocumentKind? = nil,
                                      guideAspectRatio: Double = 1.5,
                                      instructionText: String? = nil,
                                      completion: @escaping (CapturedDocument?) -> Void) {
        DocumentScanner.presentCapture(from: presenter,
                                       expecting: expecting,
                                       guideAspectRatio: guideAspectRatio,
                                       instructionText: instructionText,
                                       completion: completion)
    }
}
