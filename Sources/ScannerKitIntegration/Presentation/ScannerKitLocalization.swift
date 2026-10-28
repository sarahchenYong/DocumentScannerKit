import Foundation

public struct ScannerKitLocalization: Sendable {
    public var languageCode: String
    public var title: String?
    public var instructionText: String?
    public var cancelText: String?

    public init(
        languageCode: String = "en",
        title: String? = nil,
        instructionText: String? = nil,
        cancelText: String? = nil
    ) {
        self.languageCode = languageCode
        self.title = title
        self.instructionText = instructionText
        self.cancelText = cancelText
    }
}
