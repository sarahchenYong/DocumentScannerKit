import Foundation

public struct ScannerKitFieldRequirements: Sendable {
    public var requiredFields: Set<String>
    public var optionalFields: Set<String>

    public init(requiredFields: Set<String> = [], optionalFields: Set<String> = []) {
        self.requiredFields = requiredFields
        self.optionalFields = optionalFields
    }
}
