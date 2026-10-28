#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Packaging/ScannerKitBinary.xcodeproj"
BUILD="$ROOT/Packaging/build"
OUT="$ROOT/Examples/ScannerKitExample/Frameworks/ScannerKit.xcframework"

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"

for platform in iOS "iOS Simulator"; do
  name="${platform// /-}"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme ScannerKit \
    -destination "generic/platform=$platform" \
    -archivePath "$BUILD/$name.xcarchive" \
    -configuration Release \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO
done

for framework in ScannerKit DocumentScannerKit IDScanner; do
  output="$ROOT/Examples/ScannerKitExample/Frameworks/$framework.xcframework"
  rm -rf "$output"
  xcodebuild -create-xcframework -allow-internal-distribution \
    -framework "$BUILD/iOS.xcarchive/Products/Library/Frameworks/$framework.framework" \
    -framework "$BUILD/iOS-Simulator.xcarchive/Products/Library/Frameworks/$framework.framework" \
    -output "$output"
done

echo "Created $OUT"
