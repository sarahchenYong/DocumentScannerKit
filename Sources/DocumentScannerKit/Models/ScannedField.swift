//
//  ScannedField.swift
//  DocumentScannerKit
//
//  The normalized, type-agnostic unit of extracted data. Every value a scanner
//  can return — across passports, visas, national IDs, driving licences and
//  bank cheques — is expressed as a `ScannedField` with a canonical key, a
//  human label, a category, and an optional OCR confidence. `ScannedFieldKey`
//  is an extensible string wrapper (like `Notification.Name`): the SDK ships a
//  large catalogue of standard keys, and callers can mint their own.
//

import Foundation

// MARK: - Field category

/// Broad grouping used to organize fields in UIs and exports.
public enum FieldCategory: String, Codable, Sendable, CaseIterable {
    case personal     // name, DOB, sex, nationality, photo-derived
    case document     // numbers, issuing authority, validity dates
    case travel       // visa / entry-permit specifics
    case address      // residential / mailing address
    case banking      // cheque & account details
    case vehicle      // driving-licence specifics
    case business     // trade-licence / company specifics
    case other
}

// MARK: - Canonical field key

/// A canonical, extensible identifier for a piece of scanned data.
///
/// Use the provided constants (`.fullName`, `.documentNumber`, …) for stable,
/// cross-document keys; construct your own with `ScannedFieldKey("myKey")` for
/// anything bespoke.
public struct ScannedFieldKey: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public extension ScannedFieldKey {
    // -- Personal -------------------------------------------------------
    static let fullName        = ScannedFieldKey("fullName")
    static let surname         = ScannedFieldKey("surname")
    static let givenNames      = ScannedFieldKey("givenNames")
    static let middleName      = ScannedFieldKey("middleName")
    static let maidenName      = ScannedFieldKey("maidenName")
    static let fathersName     = ScannedFieldKey("fathersName")
    static let mothersName     = ScannedFieldKey("mothersName")
    static let spouseName      = ScannedFieldKey("spouseName")
    static let dateOfBirth     = ScannedFieldKey("dateOfBirth")
    static let placeOfBirth    = ScannedFieldKey("placeOfBirth")
    static let sex             = ScannedFieldKey("sex")
    static let nationality     = ScannedFieldKey("nationality")
    static let nationalityCode = ScannedFieldKey("nationalityCode")
    static let bloodGroup      = ScannedFieldKey("bloodGroup")

    // -- Document / ID --------------------------------------------------
    static let documentType      = ScannedFieldKey("documentType")
    static let documentSubtype   = ScannedFieldKey("documentSubtype")
    static let documentNumber    = ScannedFieldKey("documentNumber")
    static let passportNumber    = ScannedFieldKey("passportNumber")
    static let nationalIDNumber  = ScannedFieldKey("nationalIDNumber")
    static let emiratesIDNumber  = ScannedFieldKey("emiratesIDNumber")
    static let fileNumber        = ScannedFieldKey("fileNumber")
    static let personalNumber    = ScannedFieldKey("personalNumber")
    static let optionalData      = ScannedFieldKey("optionalData")
    static let issuingCountry    = ScannedFieldKey("issuingCountry")
    static let issuingState      = ScannedFieldKey("issuingState")
    static let issuingAuthority  = ScannedFieldKey("issuingAuthority")
    static let placeOfIssue      = ScannedFieldKey("placeOfIssue")
    static let dateOfIssue       = ScannedFieldKey("dateOfIssue")
    static let dateOfExpiry      = ScannedFieldKey("dateOfExpiry")
    static let cardNumber        = ScannedFieldKey("cardNumber")

    // -- Travel / visa --------------------------------------------------
    static let visaType        = ScannedFieldKey("visaType")
    static let visaNumber      = ScannedFieldKey("visaNumber")
    static let visaClass       = ScannedFieldKey("visaClass")
    static let sponsor         = ScannedFieldKey("sponsor")
    static let profession      = ScannedFieldKey("profession")
    static let occupation      = ScannedFieldKey("occupation")
    static let employer        = ScannedFieldKey("employer")
    static let entryType       = ScannedFieldKey("entryType")
    static let numberOfEntries = ScannedFieldKey("numberOfEntries")
    static let durationOfStay  = ScannedFieldKey("durationOfStay")
    static let portOfEntry     = ScannedFieldKey("portOfEntry")
    static let validFrom       = ScannedFieldKey("validFrom")
    static let validUntil      = ScannedFieldKey("validUntil")

    // -- Address --------------------------------------------------------
    static let address    = ScannedFieldKey("address")
    static let street     = ScannedFieldKey("street")
    static let city       = ScannedFieldKey("city")
    static let stateOrProvince = ScannedFieldKey("stateOrProvince")
    static let postalCode = ScannedFieldKey("postalCode")
    static let country    = ScannedFieldKey("country")

    // -- Vehicle / driving licence -------------------------------------
    static let licenseNumber     = ScannedFieldKey("licenseNumber")
    static let licenseClass      = ScannedFieldKey("licenseClass")
    static let vehicleCategories = ScannedFieldKey("vehicleCategories")
    static let restrictions      = ScannedFieldKey("restrictions")
    static let endorsements      = ScannedFieldKey("endorsements")

    // Business / trade licence
    static let tradeName          = ScannedFieldKey("tradeName")
    static let legalForm          = ScannedFieldKey("legalForm")
    static let businessActivity   = ScannedFieldKey("businessActivity")
    static let registrationNumber = ScannedFieldKey("registrationNumber")

    // -- Banking / cheque ----------------------------------------------
    static let payeeName       = ScannedFieldKey("payeeName")
    static let accountHolder   = ScannedFieldKey("accountHolder")
    static let bankName        = ScannedFieldKey("bankName")
    static let branchName      = ScannedFieldKey("branchName")
    static let accountNumber   = ScannedFieldKey("accountNumber")
    static let iban            = ScannedFieldKey("iban")
    static let swiftCode       = ScannedFieldKey("swiftCode")
    static let routingNumber   = ScannedFieldKey("routingNumber")
    static let sortCode        = ScannedFieldKey("sortCode")
    static let chequeNumber    = ScannedFieldKey("chequeNumber")
    static let micrLine        = ScannedFieldKey("micrLine")
    // Machine-read segments of a confidently decoded E-13B MICR band, kept
    // separate from the heuristic (label-sourced) fields above. The routing
    // number has no other source, so it lives in `routingNumber` directly.
    static let micrChequeNumber  = ScannedFieldKey("micrChequeNumber")
    static let micrAccountNumber = ScannedFieldKey("micrAccountNumber")
    /// All MICR digits in band order (cheque + routing + account), combined.
    static let receiptNumber     = ScannedFieldKey("receiptNumber")
    static let amountInWords   = ScannedFieldKey("amountInWords")
    static let amountInFigures = ScannedFieldKey("amountInFigures")
    static let amountValue     = ScannedFieldKey("amountValue")
    static let currency        = ScannedFieldKey("currency")
    static let chequeDate      = ScannedFieldKey("chequeDate")

    // -- Misc -----------------------------------------------------------
    static let detectedDate = ScannedFieldKey("detectedDate")
}

// MARK: - Scanned field

public struct ScannedField: Codable, Equatable, Sendable, Identifiable {
    public let key: ScannedFieldKey
    /// Human-readable label, suitable for display (e.g. "Date of Birth").
    public let label: String
    public let value: String
    public let category: FieldCategory
    /// How reliable this value is, 0…1. Measured where possible (E-13B MICR
    /// glyph-match quality, check-digit-validated MRZ), otherwise calibrated
    /// to the extraction mechanism (format/list matches high, labelled values
    /// high, positional heuristics medium, handwriting low). Nil only for
    /// fields built by callers that didn't set one.
    public let confidence: Double?

    /// `confidence` as whole percent (e.g. 86), for display.
    public var confidencePercent: Int? { confidence.map { Int(($0 * 100).rounded()) } }

    public var id: String { "\(key.rawValue)|\(value)" }

    public init(key: ScannedFieldKey, label: String, value: String,
                category: FieldCategory, confidence: Double? = nil) {
        self.key = key
        self.label = label
        self.value = value
        self.category = category
        self.confidence = confidence
    }
}
