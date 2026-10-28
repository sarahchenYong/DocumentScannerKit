# DocumentScannerKit

A plug-and-play document scanner for Apple platforms. Add the package, present
one view, and get a fully-parsed `ScannedDocument` back — the SDK identifies
**what** the document is and extracts **every field** it can.

| Recognized | Extracted |
|---|---|
| Passport (front / back) | Names, document no., nationality, dates, sex, MRZ |
| Visa / residence permit | MRZ + visa labels (sponsor, profession, entry type…) |
| Emirates ID (front & back) | ID number `784-…`, card number, occupation, employer |
| National ID / driving licence | Licence no., classes, holder details |
| **Bank cheque** | Payee, bank, account no., IBAN, cheque no., amount in words & figures, currency, date, MICR |
| **Utility bill** (including DEWA) | Service / billing address |
| **Business card** | Printed office address |
| **Address note** | Labelled, multi-line printed or handwritten address |

Detection and extraction are powered entirely by the protected on-device
frameworks. The scanner implementation, OCR, MRZ parsing, classification and
license enforcement are distributed as XCFramework binaries; only the public
integration layer is included as Swift source.

## Installation

Swift Package Manager. In Xcode: **File ▸ Add Package Dependencies…** and point
at this repository, or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sarahchenYong/DocumentScannerKit.git", from: "1.0.0")
]
```

Then add to your app target's **Info.plist**:

```
NSCameraUsageDescription = "We use the camera to scan documents."
```

> Requires iOS 16+. The package includes device and simulator XCFramework
> slices. The protected implementation is not distributed as Swift source.

## Two modes: auto vs manual

The caller decides how the scanner identifies the document:

| Mode | Behavior |
|---|---|
| `.auto` | Detect whatever is presented. Auto-captures MRZ documents (check-digit gated) and, once the classifier is confident and stable, non-MRZ documents too. |
| `.manual(_:)` | The caller declares the document type up front (e.g. `.passportFront`, `.passportBack`, `.emiratesIDFront`). The scanner targets it, only auto-captures on a match, and tags every result with `expectedType` + `matchesExpectedType`. If a *different* type is presented (e.g. the back when you chose the front), it prompts the user to **switch to it or keep scanning the chosen one**. |

```swift
// Auto — let the SDK figure it out
DocumentScannerView(mode: .auto) { doc in … }

// Manual — "I am scanning an Emirates ID front"
DocumentScannerView(mode: .manual(.emiratesIDFront)) { doc in
    guard doc.matchesExpectedType else { /* user showed the wrong document */ return }
    …
}
```

The same applies to the UIKit facade and the offline parser:

```swift
DocumentScanner.present(from: self, mode: .manual(.bankCheque)) { doc in … }
let doc = try DocumentParser.parse(image: cgImage, expecting: .passportFront)
```

The live camera shows a **boundary guide** sized to the chosen document
(passport/visa, ID card, or the wider cheque) and only auto-captures once a real
document is detected *filling that frame* — it never fires on a stray word in
view. The outline turns green when the document is aligned.

For accuracy, the live stream is used only to **detect and aim**: when the
document is framed and stable, the SDK takes a **full-resolution still photo**
and extracts from that (not from motion-blurred preview frames). Every image is
**perspective-corrected and cropped to the document, then OCR'd in two passes**
(sharp for print, enhanced for handwriting) and merged — which is what makes
live results match a static photo.

Fine-grained control lives on `ScannerConfiguration` (`autoCaptureMRZ`,
`autoCaptureOnClassification`, `minimumAutoConfidence`, `votesNeeded`,
`requiresDocumentInFrame`, `minimumFillRatio`, `promptOnTypeMismatch`,
`showsGuideOverlay`, `guideAspectRatio`, `acceptedDocumentTypes`,
button/instruction text).

## Usage

### SwiftUI

```swift
import SwiftUI
import DocumentScannerKit

struct Demo: View {
    @State private var scanning = false
    @State private var document: ScannedDocument?

    var body: some View {
        Button("Scan") { scanning = true }
            .sheet(isPresented: $scanning) {
                DocumentScannerView { result in
                    document = result      // ← fully parsed
                    scanning = false
                } onCancel: {
                    scanning = false
                }
                .ignoresSafeArea()
            }
    }
}
```

### UIKit

```swift
import DocumentScannerKit

// Closure
DocumentScanner.present(from: self) { document in
    guard let document else { return }      // nil == cancelled
    print(document.documentType, document.fullName ?? "")
}

// async/await
if let document = await DocumentScanner.scan(from: self) {
    print(document.jsonString)
}
```

### Parse an image you already have (no camera)

```swift
let document = try DocumentParser.parse(image: cgImage)
```

### Parse OCR text you already have

```swift
let document = DocumentParser.parse(recognizedLines: ["…", "…"])
```

## The result: `ScannedDocument`

```swift
document.documentType          // .bankCheque, .passportDataPage, .emiratesIDFront, …
document.confidence            // 0...1
document.fields                // [ScannedField] — normalized, ordered, de-duplicated

// One-line typed access to the common fields:
document.fullName
document.documentNumber
document.dateOfExpiry
document.payeeName
document.amountInFigures
document.iban

// Generic access by canonical key:
document[.emiratesIDNumber]
document[.sponsor]

document.fields(in: .banking)  // filter by category
document.mrz                   // full ICAO 9303 zone when present
document.rawText               // OCR lines, exactly as recognized
document.jsonString            // the whole thing, serialized (Codable)
```

Every value is a `ScannedField` carrying a canonical `key`, a display `label`,
a `category` (personal / document / travel / address / banking / vehicle), and
an optional OCR `confidence`. `ScannedFieldKey` ships a large catalogue of
standard keys and is extensible (`ScannedFieldKey("yourCustomKey")`).

### Configuration

```swift
let config = ScannerConfiguration(
    acceptedDocumentTypes: [.passportDataPage, .emiratesIDFront], // nil = accept all
    autoCaptureMRZ: true,        // auto-emit on a valid MRZ across frames
    votesNeeded: 2,              // frames that must agree before auto-emit
    showsCaptureButton: true,    // built-in manual Capture overlay
    instructionText: "Hold steady, then tap Capture."
)
DocumentScannerView(configuration: config) { … }
```

## Repository layout

```
Package.swift                       — the SPM manifest (product: DocumentScannerKit)
Sources/DocumentScannerKit/
  Models/                           — ScannedDocument, ScannedField, DocumentKind, ScanMode
  Parsing/                          — MRZ, classifier, cheque, field extractor, orchestrator
  Scanning/                         — camera UI: SwiftUI view, UIKit VC, presenter (iOS-only)
Tests/DocumentScannerKitTests/      — unit tests (run with `swift test`)
Example/
  DocumentScannerExample.xcodeproj  — SwiftUI demo app consuming the package
  UIKitExample.xcodeproj            — UIKit demo app consuming the package
```

## Testing

```bash
swift test                                  # parsing logic, on macOS
# Build / run a demo app on a device for the live camera:
xcodebuild -project Example/DocumentScannerExample.xcodeproj \
           -scheme DocumentScannerExample -destination 'generic/platform=iOS' build   # SwiftUI
xcodebuild -project Example/UIKitExample.xcodeproj \
           -scheme UIKitExample -destination 'generic/platform=iOS' build             # UIKit
```

## Notes & limits

- **MICR (E-13B) band** is read approximately by Vision, so cheque/account
  numbers are recovered from digit groups with labeled fallbacks — verify
  against the printed value for banking-critical use.
- The bank-name list and Emirates-ID/IBAN patterns are **UAE-focused**; extend
  `DocumentClassifier.bankNames` and the field specs for other regions.
- The camera does not run in the iOS Simulator — use `swift test` or the demo
  app's in-app self-test to validate parsing, and a physical device for capture.
