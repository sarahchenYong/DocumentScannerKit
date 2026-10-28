import Foundation

/// Presentation policy for the host application's scanner flow. The actual
/// camera UI and capture engine remain inside the binary framework.
public struct ScannerKitPresentation: Sendable {
    public var showsCancelAction: Bool
    public var instructionText: String?
    public var appearance: ScannerKitAppearance

    public init(
        showsCancelAction: Bool = true,
        instructionText: String? = nil,
        appearance: ScannerKitAppearance = ScannerKitAppearance()
    ) {
        self.showsCancelAction = showsCancelAction
        self.instructionText = instructionText
        self.appearance = appearance
    }
}
