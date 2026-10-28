// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DocumentScannerKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "DocumentScannerKit", targets: ["ScannerKitIntegration", "ScannerKit", "DocumentScannerKit", "IDScanner"])
    ],
    targets: [
        .target(name: "ScannerKitIntegration", dependencies: ["ScannerKit", "DocumentScannerKit", "IDScanner"], path: "Sources/ScannerKitIntegration"),
        .testTarget(name: "ScannerKitIntegrationTests", dependencies: ["ScannerKitIntegration"], path: "Tests/ScannerKitIntegrationTests"),
        .binaryTarget(name: "ScannerKit", path: "Frameworks/ScannerKit.xcframework"),
        .binaryTarget(name: "DocumentScannerKit", path: "Frameworks/DocumentScannerKit.xcframework"),
        .binaryTarget(name: "IDScanner", path: "Frameworks/IDScanner.xcframework")
    ]
)
