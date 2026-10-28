@_exported import DocumentScannerKit
import Foundation
import IDScanner
import Security
import UIKit

public struct ScannerKitConfiguration: Sendable, Equatable {

    public let licenseKey: String
    public var usesMRZFallback: Bool
    public var productIdentifier: String

    public init(licenseKey: String, usesMRZFallback: Bool = false) {
        self.licenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.productIdentifier = Bundle.main.bundleIdentifier ?? ""
        self.usesMRZFallback = usesMRZFallback
    }

    @available(*, deprecated, message: "The bundle identifier is detected automatically.")
    public init(licenseKey: String, productIdentifier: String, usesMRZFallback: Bool = false) {
        self.licenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.productIdentifier = Bundle.main.bundleIdentifier ?? productIdentifier
        self.usesMRZFallback = usesMRZFallback
    }
}

public enum ScannerKitError: LocalizedError, Equatable {
    case notConfigured
    case invalidLicenseKey
    case licenseNotActivated
    case bundleNotAllowed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "ScannerKit must be configured before scanning."
        case .invalidLicenseKey: return "A non-empty ScannerKit license key is required."
        case .licenseNotActivated: return "ScannerKit requires an active license."
        case .bundleNotAllowed: return "This app bundle is not licensed for ScannerKit."
        }
    }
}

public struct ScannerKitLicense: Codable, Sendable, Equatable {

    public let customerIdentifier: String
    public let expiresAt: Date?
    public let features: Set<String>

    public init(customerIdentifier: String, expiresAt: Date?, features: Set<String>) {
        self.customerIdentifier = customerIdentifier
        self.expiresAt = expiresAt
        self.features = features
    }

    public var isExpired: Bool {
        expiresAt.map { $0 <= Date() } ?? false
    }
}

public protocol ScannerKitLicenseValidating: Sendable {
    func validate(licenseKey: String, productIdentifier: String) async throws -> ScannerKitLicense
}

/// HTTPS client for a ScannerKit licensing backend. The server owns key
/// issuance, revocation, entitlement checks, and any signing secrets.
public struct ScannerKitRemoteLicenseValidator: ScannerKitLicenseValidating {

    public let endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    public func validate(licenseKey: String, productIdentifier: String) async throws -> ScannerKitLicense {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(licenseKey: licenseKey,
                                                            productIdentifier: productIdentifier,
                                                            bundleIdentifier: Bundle.main.bundleIdentifier))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScannerKitLicense.self, from: data)
    }

    private struct Request: Encodable {
        let licenseKey: String
        let productIdentifier: String
        let bundleIdentifier: String?
    }
}

private extension ScannerKitRemoteLicenseValidator {
    static let hostedEndpoint = URL(string: "https://scannerkit-licenses.ashokdy.workers.dev/v1/licenses/validate")!
}

/// Public entry point for the commercial scanner SDK.
///
/// The app supplies a license key once during launch, then presents scanning
/// through this type. Server-side license verification can be added without
/// changing the customer-facing scan API.
@MainActor
public enum ScannerKit {

    private static let permittedBundlePrefixes = [
        "com.ios.nesnar.tamkeen",
        "com.binghatti.workspace"
    ]

    private static var configuration: ScannerKitConfiguration?
    public private(set) static var license: ScannerKitLicense?

    public static func configure(_ configuration: ScannerKitConfiguration) throws {
        guard !configuration.licenseKey.isEmpty else {
            throw ScannerKitError.invalidLicenseKey
        }
        guard permittedBundlePrefixes.contains(where: { prefix in
            configuration.productIdentifier == prefix || configuration.productIdentifier.hasPrefix(prefix + ".")
        }) else {
            throw ScannerKitError.bundleNotAllowed
        }

        self.configuration = configuration
    }

    /// Validates the configured key against your licensing backend. Call this
    /// during launch and before enabling scanner features.
    public static func activate(using validator: some ScannerKitLicenseValidating) async throws {
        guard let configuration else { throw ScannerKitError.notConfigured }

        if let cached = cachedLicense(for: configuration), !cached.isExpired {
            self.license = cached
            return
        }

        let license = try await validator.validate(licenseKey: configuration.licenseKey,
                                                    productIdentifier: configuration.productIdentifier)
        guard !license.isExpired else { throw ScannerKitError.licenseNotActivated }
        self.license = license
        cache(license, for: configuration)
    }

    /// Activates against the hosted ScannerKit licensing service. Applications
    /// only need to provide their customer license key to `configure`.
    public static func activate() async throws {
        try await activate(using: ScannerKitRemoteLicenseValidator(endpoint: ScannerKitRemoteLicenseValidator.hostedEndpoint))
    }

    public static func present(from presenter: UIViewController,
                               configuration: ScannerConfiguration = .default,
                               completion: @escaping (Result<ScannedDocument, ScannerKitError>) -> Void) {
        guard self.configuration != nil else {
            completion(.failure(.notConfigured))
            return
        }
        guard license != nil else {
            completion(.failure(.licenseNotActivated))
            return
        }

        IDScanner.present(from: presenter, configuration: configuration) { document in
            guard let document else { return }
            completion(.success(document))
        }
    }

    public static func presentCapture(from presenter: UIViewController,
                                      expecting: DocumentKind? = nil,
                                      guideAspectRatio: Double = 1.5,
                                      instructionText: String? = nil,
                                      completion: @escaping (CapturedDocument?) -> Void) {
        guard configuration != nil, license != nil else {
            completion(nil)
            return
        }
        IDScanner.presentCapture(from: presenter,
                                 expecting: expecting,
                                 guideAspectRatio: guideAspectRatio,
                                 instructionText: instructionText,
                                 completion: completion)
    }

    private static let keychainService = "com.scannerkit.license"

    private static func keychainAccount(for configuration: ScannerKitConfiguration) -> String {
        "\(configuration.productIdentifier):\(configuration.licenseKey)"
    }

    private static func cache(_ license: ScannerKitLicense, for configuration: ScannerKitConfiguration) {
        guard let data = try? JSONEncoder().encode(license) else { return }
        let account = keychainAccount(for: configuration)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func cachedLicense(for configuration: ScannerKitConfiguration) -> ScannerKitLicense? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: keychainAccount(for: configuration),
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ScannerKitLicense.self, from: data)
    }
}
