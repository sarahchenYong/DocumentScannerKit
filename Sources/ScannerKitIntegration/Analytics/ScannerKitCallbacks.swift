import Foundation

public struct ScannerKitCallbacks: Sendable {
    public var onStarted: (@Sendable () -> Void)?
    public var onCancelled: (@Sendable () -> Void)?
    public var onFailure: (@Sendable (String) -> Void)?

    public init(
        onStarted: (@Sendable () -> Void)? = nil,
        onCancelled: (@Sendable () -> Void)? = nil,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) {
        self.onStarted = onStarted
        self.onCancelled = onCancelled
        self.onFailure = onFailure
    }
}
