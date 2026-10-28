import Foundation

public enum ScannerKitDocumentMode: String, CaseIterable, Sendable {
    case identity
    case passport
    case nationalID
    case proofOfAddress
    case cheque
    case iban
}
