import Foundation

public struct ScannerKitAnalyticsHooks: Sendable {
    public var onScanStarted: (@Sendable (ScannerKitDocumentMode) -> Void)?
    public var onScanCompleted: (@Sendable (ScannerKitDocumentMode) -> Void)?
    public var onScanFailed: (@Sendable (ScannerKitDocumentMode, String) -> Void)?

    public init(
        onScanStarted: (@Sendable (ScannerKitDocumentMode) -> Void)? = nil,
        onScanCompleted: (@Sendable (ScannerKitDocumentMode) -> Void)? = nil,
        onScanFailed: (@Sendable (ScannerKitDocumentMode, String) -> Void)? = nil
    ) {
        self.onScanStarted = onScanStarted
        self.onScanCompleted = onScanCompleted
        self.onScanFailed = onScanFailed
    }
}
