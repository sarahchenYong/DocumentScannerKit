import CoreImage
import DocumentScannerKit
import ImageIO
@_implementationOnly import MRZParser
@_implementationOnly import MRZScanner
import UIKit
import Vision

/// The identity-document scanner facade.
///
/// Both engines use `DocumentScannerKit` for the camera journey. Set
/// `usesDocumentScannerKitParser` to `false` to use MRZScanner on the
/// captured still instead.
@MainActor
public enum IDScanner {

    /// `true` uses DocumentScannerKit's complete parser. `false` uses
    /// MRZScanner for checksum-validated MRZ data after the same capture UI.
    public static var usesDocumentScannerKitParser = true

    public static func present(from presenter: UIViewController,
                               configuration: ScannerConfiguration = .default,
                               completion: @escaping (ScannedDocument?) -> Void) {
        guard !usesDocumentScannerKitParser else {
            DocumentScanner.present(from: presenter, configuration: configuration, completion: completion)
            return
        }

        DocumentScanner.present(from: presenter, configuration: configuration,
                                onCapturedImage: { image in
            Task {
                let document = await MRZStillReader.read(image: image,
                                                         expectedType: configuration.mode.expectedType)
                completion(document)
            }
        }, completion: completion)
    }

    /// Presents the camera for an attachment that does not require identity
    /// parsing, while retaining DocumentScannerKit's camera UI and cropping.
    public static func presentCapture(from presenter: UIViewController,
                                      expecting: DocumentKind? = nil,
                                      guideAspectRatio: Double = 1.5,
                                      instructionText: String? = nil,
                                      completion: @escaping (CapturedDocument?) -> Void) {
        DocumentScanner.presentCapture(from: presenter, expecting: expecting,
                                       guideAspectRatio: guideAspectRatio,
                                       instructionText: instructionText,
                                       completion: completion)
    }
}

private enum MRZStillReader {
    static func read(image: UIImage, expectedType: DocumentKind?) async -> ScannedDocument? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let configuration = ScanningConfiguration(
            orientation: image.imageOrientation.cgImagePropertyOrientation,
            regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
            minimumTextHeight: 0.01,
            recognitionLevel: .accurate)

        do {
            guard let result = try await ciImage.scanForMRZCode(configuration: configuration)?.results else {
                return nil
            }
            return document(from: result, image: image, expectedType: expectedType)
        } catch {
            return nil
        }
    }

    private static func document(from mrz: ParserResult, image: UIImage,
                                 expectedType: DocumentKind?) -> ScannedDocument {
        let kind = documentKind(for: mrz.documentType)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let fields: [ScannedField] = [
            field(.documentType, "Document Type", documentTypeCode(mrz.documentType), .document),
            field(.issuingCountry, "Issuing Country", countryCode(mrz.issuingCountry), .document),
            field(.surname, "Surname", mrz.name.surname, .personal),
            field(.givenNames, "Given Names", mrz.name.givenNames ?? "", .personal),
            field(.documentNumber, "Document Number", mrz.documentNumber, .document),
            field(.nationalityCode, "Nationality", mrz.nationalityCountryCode, .personal),
            field(.dateOfBirth, "Date of Birth", dateFormatter.string(from: mrz.birthdate), .personal),
            field(.sex, "Sex", sexCode(mrz.sex), .personal),
            field(.dateOfExpiry, "Expiry Date", mrz.expiryDate.map(dateFormatter.string(from:)) ?? "", .document),
            field(.optionalData, "Personal Number", mrz.optionalData ?? "", .document),
        ].filter { !$0.value.isEmpty }

        var document = ScannedDocument(documentType: kind, confidence: 0.98,
                                       classificationSignals: ["MRZScanner checksum-valid MRZ"],
                                       fields: fields, rawText: [], scannedAt: Date(),
                                       expectedType: expectedType)
        document.image = image.jpegData(compressionQuality: 0.95)
        return document
    }

    private static func field(_ key: ScannedFieldKey, _ label: String, _ value: String,
                              _ category: FieldCategory) -> ScannedField {
        ScannedField(key: key, label: label, value: value, category: category, confidence: 0.98)
    }

    private static func documentKind(for type: ParserResult.DocumentType) -> DocumentKind {
        switch type {
        case .passport: return .passportFront
        case .visa: return .visa
        case .other: return .emiratesIDBack
        }
    }

    private static func documentTypeCode(_ type: ParserResult.DocumentType) -> String {
        switch type {
        case .passport: return "P"
        case .visa: return "V"
        case .other(let character): return String(character)
        }
    }

    private static func countryCode(_ country: ParserResult.Country) -> String {
        switch country {
        case .russia: return "RUS"
        case .other(let code): return code
        }
    }

    private static func sexCode(_ sex: ParserResult.Sex) -> String {
        switch sex {
        case .male: return "M"
        case .female: return "F"
        case .unspecified: return ""
        case .other(let character): return String(character)
        }
    }
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
