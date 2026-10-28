import Foundation

/// App-specific customization point for Tamkeen's private scanner binary.
/// Keep navigation, presentation policy, and result mapping here. Scanner
/// algorithms, OCR/MRZ parsing, and licensing remain inside the XCFramework.
public enum ScannerKitIntegration {
    public static let minimumSupportediOSMajorVersion = 16
}
