//
//  ScanMode.swift
//  DocumentScannerKit
//
//  How a scanning session decides what it's looking at.
//
//    • .auto                 — identify whatever document is presented.
//    • .manual(.passport…)   — the caller declares the document up front; the
//                              scanner targets that type, auto-captures only on
//                              a match, and flags mismatches on the result.
//

import Foundation

public enum ScanMode: Equatable, Sendable {
    /// Auto-detect the document type from what the camera sees.
    case auto
    /// The caller states exactly which document is being scanned.
    case manual(DocumentKind)

    /// The declared type in manual mode, or `nil` in auto mode.
    public var expectedType: DocumentKind? {
        if case .manual(let kind) = self { return kind }
        return nil
    }

    public var isAuto: Bool { self == .auto }
}
