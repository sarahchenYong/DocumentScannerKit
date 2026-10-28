//
//  ScannerSessionLifecycle.swift
//  DocumentScannerKit
//
//  Keeps camera appearance and configuration events independent. The capture
//  session may only start after both have completed.
//

struct ScannerSessionLifecycle {

    private(set) var isConfigured = false
    private(set) var wantsSessionRunning = false

    mutating func requestStart() {
        wantsSessionRunning = true
    }

    mutating func requestStop() {
        wantsSessionRunning = false
    }

    mutating func markConfigured() {
        isConfigured = true
    }

    var shouldStart: Bool {
        isConfigured && wantsSessionRunning
    }
}
