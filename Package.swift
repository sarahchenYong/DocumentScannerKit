// swift-tools-version: 5.9
//
//  DocumentScannerKit — a plug-and-play document/ID/cheque scanner for Apple
//  platforms. Add the package, present one view, get a fully-parsed
//  `ScannedDocument` back.
//

import PackageDescription

let package = Package(
    name: "DocumentScannerKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v12),   // parsing + Vision OCR run on macOS; live camera is iOS-only
    ],
    products: [
        .library(name: "DocumentScannerKit", targets: ["DocumentScannerKit"]),
    ],
    targets: [
        .target(
            name: "DocumentScannerKit",
            path: "Sources/DocumentScannerKit"
        ),
        .testTarget(
            name: "DocumentScannerKitTests",
            dependencies: ["DocumentScannerKit"],
            path: "Tests/DocumentScannerKitTests"
        ),
    ]
)
