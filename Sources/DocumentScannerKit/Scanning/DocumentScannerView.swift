//
//  DocumentScannerView.swift
//  DocumentScannerKit
//
//  SwiftUI entry point. Drop it in a sheet or navigation destination and
//  receive a fully-parsed `ScannedDocument` via the result closure.
//
//      .sheet(isPresented: $scanning) {
//          DocumentScannerView { result in
//              self.document = result
//              scanning = false
//          } onCancel: {
//              scanning = false
//          }
//      }
//

#if canImport(UIKit) && canImport(AVFoundation)
import SwiftUI

public struct DocumentScannerView: UIViewControllerRepresentable {
    private let configuration: ScannerConfiguration
    private let onResult: (ScannedDocument) -> Void
    private let onCapturedImage: ((UIImage) -> Void)?
    private let onCancel: (() -> Void)?

    /// `onCapturedImage` (optional) fires the moment the still is taken and
    /// cropped to the document — before parsing — so the host can dismiss the
    /// scanner and show the image with its own progress UI; `onResult` still
    /// follows when extraction completes.
    public init(configuration: ScannerConfiguration = .default,
                onResult: @escaping (ScannedDocument) -> Void,
                onCapturedImage: ((UIImage) -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        self.configuration = configuration
        self.onResult = onResult
        self.onCapturedImage = onCapturedImage
        self.onCancel = onCancel
    }

    /// Convenience: pick the mode directly — `.auto` or `.manual(.passport…)`.
    public init(mode: ScanMode,
                onResult: @escaping (ScannedDocument) -> Void,
                onCapturedImage: ((UIImage) -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        self.init(configuration: ScannerConfiguration(mode: mode), onResult: onResult,
                  onCapturedImage: onCapturedImage, onCancel: onCancel)
    }

    public func makeUIViewController(context: Context) -> DocumentScannerViewController {
        let vc = DocumentScannerViewController(configuration: configuration)
        vc.onResult = onResult
        vc.onCapturedImage = onCapturedImage
        vc.onCancel = onCancel
        return vc
    }

    public func updateUIViewController(_ vc: DocumentScannerViewController, context: Context) {}
}
#endif
