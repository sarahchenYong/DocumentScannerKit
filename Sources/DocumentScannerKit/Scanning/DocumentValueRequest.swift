//
//  DocumentValueRequest.swift
//  DocumentScannerKit
//
//  "Fill this one field from a document." A request names the value to look
//  for — how to spot it in a live preview, how to read it out of a parsed
//  page, and what to say when a page doesn't carry it — and every source
//  then answers it identically:
//
//      DocumentScanner.presentValueScan(from: self, request: .iban) { … }
//      DocumentReader.readValue(pdfFilePath: url, request: .iban) { … }
//      DocumentSourceMenu(presenter: self, request: .iban)      // all three
//
//  Adding a value a form wants — an account number, a trade licence number,
//  a policy number — is one `DocumentValueRequest`, not a new flow.
//

import Foundation

public struct DocumentValueRequest: Sendable {

    /// A cheap test against the live preview's recognized lines: does the
    /// framed page show the value yet? Auto-capture fires only when this
    /// passes, so the shutter never trips on empty space, and never on a
    /// document whose value hasn't resolved. The manual shutter stays live
    /// regardless. nil leaves auto-capture ungated.
    public var liveGate: (@Sendable ([String]) -> Bool)?

    /// The value in a fully parsed page, or nil when it carries none.
    public var read: @Sendable (ScannedDocument) -> String?

    /// The camera's instruction line — what to point it at.
    public var instruction: String

    /// Shown when a document the user supplied carries no such value.
    public var notFoundMessage: String

    /// The camera guide's shape. Most value searches want the landscape
    /// guide: cheques, letterheads and statements are wider than tall.
    public var guideAspectRatio: Double

    /// How many pages of a picked PDF to search before giving up. A bank
    /// letter puts the value on page one; a statement can bury it deeper,
    /// and OCR is not free, so the default stops short of "all".
    public var pageLimit: Int

    public init(instruction: String,
                notFoundMessage: String,
                guideAspectRatio: Double = 1.5,
                pageLimit: Int = 5,
                liveGate: (@Sendable ([String]) -> Bool)? = nil,
                read: @escaping @Sendable (ScannedDocument) -> String?) {
        self.instruction = instruction
        self.notFoundMessage = notFoundMessage
        self.guideAspectRatio = guideAspectRatio
        self.pageLimit = pageLimit
        self.liveGate = liveGate
        self.read = read
    }
}

public extension DocumentValueRequest {

    /// An IBAN, off anything that shows one: a cheque, a bank letter, a
    /// statement, a number written on plain paper. Any country's IBAN
    /// qualifies and no label is required — a candidate is cut to its
    /// country's registered length and proven by the mod-97 check digits,
    /// with the usual letter-for-digit handwriting misreads repaired first.
    static let iban = DocumentValueRequest(
        instruction: "Scan a cheque, bank letter, or paper showing the IBAN",
        notFoundMessage: "No IBAN was found in this document. Please use a document that clearly shows the IBAN.",
        guideAspectRatio: DocumentKind.passportFront.guideAspectRatio,
        liveGate: { lines in IBANExtractor.extract(from: lines) != nil },
        read: { document in IBANExtractor.extract(from: document) })
}

/// What a value scan came back with. `notFound` is kept apart from
/// `cancelled` on purpose: a page the user captured that turned out not to
/// carry the value is worth telling them about, a scan they backed out of
/// is not. How to say so — an alert, a banner, a retry — is the host's call.
public enum ValueScanOutcome: Sendable {
    case found(String)
    case notFound
    case cancelled
}
