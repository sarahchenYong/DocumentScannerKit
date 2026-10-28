import Foundation

public enum ScannerKitErrorHandler {
    public static func userMessage(for error: Error) -> String {
        error.localizedDescription
    }
}
