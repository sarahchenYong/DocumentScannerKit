import Foundation

public struct ScannerKitCaptureOptions: Sendable {
    public var showsGuidanceOverlay: Bool
    public var allowsManualCapture: Bool
    public var maximumCaptureAttempts: Int

    public init(
        showsGuidanceOverlay: Bool = true,
        allowsManualCapture: Bool = true,
        maximumCaptureAttempts: Int = 3
    ) {
        self.showsGuidanceOverlay = showsGuidanceOverlay
        self.allowsManualCapture = allowsManualCapture
        self.maximumCaptureAttempts = max(1, maximumCaptureAttempts)
    }
}
