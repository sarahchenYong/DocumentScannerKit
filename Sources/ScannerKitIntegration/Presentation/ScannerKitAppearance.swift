import Foundation

public struct ScannerKitAppearance: Sendable {
    public var accentColorHex: String
    public var title: String?
    public var instructionText: String?

    public init(
        accentColorHex: String = "#0066CC",
        title: String? = nil,
        instructionText: String? = nil
    ) {
        self.accentColorHex = accentColorHex
        self.title = title
        self.instructionText = instructionText
    }
}
