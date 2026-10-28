import Foundation

/// App-owned configuration that is safe to customize without changing the
/// protected scanner or licensing implementation.
public struct ScannerKitConfiguration: Sendable {
    public var policy: ScannerKitDocumentPolicy
    public var preferredInstructionText: String?

    public init(
        policy: ScannerKitDocumentPolicy = .default,
        preferredInstructionText: String? = nil
    ) {
        self.policy = policy
        self.preferredInstructionText = preferredInstructionText
    }
}
