import Foundation

public struct ScannerKitFeatureFlags: Sendable {
    public var enablesPassportMRZ: Bool
    public var enablesNationalID: Bool
    public var enablesProofOfAddress: Bool
    public var enablesChequeReading: Bool
    public var enablesIBANExtraction: Bool

    public init(
        enablesPassportMRZ: Bool = true,
        enablesNationalID: Bool = true,
        enablesProofOfAddress: Bool = true,
        enablesChequeReading: Bool = true,
        enablesIBANExtraction: Bool = true
    ) {
        self.enablesPassportMRZ = enablesPassportMRZ
        self.enablesNationalID = enablesNationalID
        self.enablesProofOfAddress = enablesProofOfAddress
        self.enablesChequeReading = enablesChequeReading
        self.enablesIBANExtraction = enablesIBANExtraction
    }
}
