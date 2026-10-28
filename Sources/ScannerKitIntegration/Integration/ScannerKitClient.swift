import Foundation
import UIKit
import ScannerKit
import DocumentScannerKit

/// The customer-facing integration facade. All capture, OCR, classification,
/// parsing, and license enforcement remain inside the binary frameworks.
@MainActor
public enum ScannerKitClient {
    public static func configure(licenseKey: String) throws {
        try ScannerKit.configure(.init(licenseKey: licenseKey))
    }

    public static func activate() async throws {
        try await ScannerKit.activate()
    }

    public static func presentIdentityScanner(
        from presenter: UIViewController,
        configuration: ScannerConfiguration = .default,
        presentation: ScannerKitPresentation = ScannerKitPresentation(),
        callbacks: ScannerKitCallbacks = ScannerKitCallbacks(),
        completion: @escaping (Result<ScannedDocument, Error>) -> Void
    ) {
        callbacks.onStarted?()
        ScannerKit.present(
            from: presenter,
            configuration: configuration,
            completion: { result in
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    callbacks.onFailure?(error.localizedDescription)
                    completion(result)
                }
            }
        )
    }

    public static func presentCapture(
        from presenter: UIViewController,
        expecting: DocumentKind? = nil,
        options: ScannerKitCaptureOptions = ScannerKitCaptureOptions(),
        presentation: ScannerKitPresentation = ScannerKitPresentation(),
        completion: @escaping (CapturedDocument?) -> Void
    ) {
        ScannerKit.presentCapture(
            from: presenter,
            expecting: expecting,
            guideAspectRatio: 1.5,
            instructionText: presentation.instructionText,
            completion: completion
        )
    }
}
