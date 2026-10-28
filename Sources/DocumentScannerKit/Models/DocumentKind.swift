//
//  DocumentKind.swift
//  DocumentScannerKit
//

import Foundation

/// Which face of a physical document a scan shows.
public enum DocumentSide: String, Codable, Sendable {
    case front = "Front"
    case back = "Back"
    case unknown = "Unknown"
}

/// The class of document a scan was identified as.
public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case passportFront      = "Passport — Bio Page"   // data/photo page (carries the MRZ)
    case passportBack       = "Passport — Address Page"    // address / endorsements page
    case visa               = "Visa"
    case emiratesIDFront    = "ID — Front"
    case emiratesIDBack     = "ID — Back"
    case nationalID         = "National ID Card"
    case drivingLicense     = "Driving Licence"
    case residencePermit    = "Residence Permit"
    case bankCheque         = "Bank Cheque"
    case tradeLicense       = "Trade License"   // commercial / professional licence
    case utilityBill        = "Utility Bill"
    case businessCard       = "Business Card"
    case addressNote        = "Address Note"
    case unknown            = "Unknown Document"

    /// SF Symbol that visually represents the kind.
    public var symbolName: String {
        switch self {
        case .passportFront, .passportBack: return "book.closed.fill"
        case .visa:            return "airplane.circle.fill"
        case .emiratesIDFront, .emiratesIDBack, .nationalID, .residencePermit:
            return "person.text.rectangle.fill"
        case .drivingLicense:  return "car.fill"
        case .bankCheque:      return "banknote.fill"
        case .tradeLicense:    return "building.2.fill"
        case .utilityBill:     return "doc.text.fill"
        case .businessCard:    return "rectangle.text.clip.fill"
        case .addressNote:     return "pencil.line"
        case .unknown:         return "questionmark.square.dashed"
        }
    }

    /// The document face this kind represents. Kinds without distinct
    /// front/back variants (visa page, cheque, licence) report .front —
    /// they are captured face-up; .unknown only for unclassified scans.
    public var side: DocumentSide {
        switch self {
        case .passportFront, .emiratesIDFront: return .front
        case .passportBack, .emiratesIDBack: return .back
        case .visa, .nationalID, .drivingLicense, .residencePermit, .bankCheque,
             .tradeLicense, .utilityBill, .businessCard, .addressNote: return .front
        case .unknown: return .unknown
        }
    }

    /// True for the family of documents carrying a machine-readable zone.
    public var isTravelDocument: Bool {
        switch self {
        case .passportFront, .passportBack, .visa, .residencePermit: return true
        default: return false
        }
    }

    /// Map a host app's document slot/display name ("Passport Front Side",
    /// "National ID Back Side", "Visa", "Emirates ID Front" …) to the kind it
    /// names — for handing an existing UI's selection straight to the scanner.
    public init?(slotName: String) {
        let name = slotName.uppercased()
        if name.contains("PASSPORT") {
            // The host app uses "Passport Bio Page" / "Passport Address
            // Page", while other callers use Front/Back. Both vocabularies
            // must resolve to the same physical passport page.
            self = name.contains("BACK") || name.contains("ADDRESS")
                ? .passportBack : .passportFront
        }
        else if name.contains("VISA") {
            self = .visa
        }
        else if name.contains("TRADE") {        // before LICEN — "Trade Licence"
            self = .tradeLicense
        }
        else if name.contains("NATIONAL") || name.contains("EMIRATES") || name.contains("ID") {
            if name.contains("BACK") {
                self = .emiratesIDBack
            } else if name.contains("FRONT") {
                self = .emiratesIDFront
            } else {
                // A generic host slot such as "National ID" names the
                // side-agnostic document kind, not its front face.
                self = .nationalID
            }
        }
        else if name.contains("RESIDEN") {
            self = .residencePermit
        }
        else if name.contains("LICEN") || name.contains("DRIVING") {
            self = .drivingLicense
        }
        else if name.contains("CHEQUE") || name.contains("CHECK") {
            self = .bankCheque
        }
        else if name.contains("UTILITY") || name.contains("BILL") || name.contains("DEWA") {
            self = .utilityBill
        }
        else if name.contains("BUSINESS") || name.contains("CARD") {
            self = .businessCard
        }
        else if name.contains("ADDRESS") || name.contains("NOTE") || name.contains("HANDWRITTEN") {
            self = .addressNote
        }
        else {
            return nil
        }
    }

    /// Whether a live classification is an acceptable sighting of `expected`
    /// for capture purposes. Strict on front/back; tolerant of the generic
    /// national-ID classification standing in for an Emirates ID kind.
    public func isCaptureCompatible(with expected: DocumentKind) -> Bool {
        if self == expected { return true }
        // "Proof Of Address" maps to addressNote as an umbrella slot. Bills,
        // cards, passport address pages, and trade licences are all valid
        // address sources for that slot.
        if expected == .addressNote,
           [.utilityBill, .businessCard, .passportBack, .tradeLicense].contains(self) {
            return true
        }
        let idKinds: Set<DocumentKind> = [.emiratesIDFront, .emiratesIDBack, .nationalID]
        if self == .nationalID, idKinds.contains(expected) { return true }
        if expected == .nationalID, idKinds.contains(self) { return true }
        return false
    }

    /// Physical width ÷ height, used to size the on-screen capture guide to the
    /// real document so the user frames it correctly.
    public var guideAspectRatio: Double {
        switch self {
        case .passportFront, .passportBack, .visa, .residencePermit:
            return 1.42                       // ID-3 booklet page (125 × 88 mm)
        case .emiratesIDFront, .emiratesIDBack, .nationalID, .drivingLicense:
            return 1.585                      // ID-1 card (85.6 × 54 mm)
        case .bankCheque:
            return 2.2                        // typical cheque leaf
        case .tradeLicense:
            return 0.71                       // A4 portrait certificate
        case .utilityBill, .addressNote:
            return 0.71                       // A4 / letter page
        case .businessCard:
            return 1.75                       // typical landscape business card
        case .unknown:
            return 1.7
        }
    }
}
