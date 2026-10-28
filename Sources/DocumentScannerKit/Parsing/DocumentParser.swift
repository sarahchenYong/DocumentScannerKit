//
//  DocumentParser.swift
//  DocumentScannerKit
//
//  The brain of the SDK: turns raw OCR lines (or an image) into a fully
//  populated `ScannedDocument`. It runs MRZ recovery, document classification,
//  and the type-appropriate field extraction (cheque parser for cheques; MRZ +
//  labeled-field extraction for everything else), then normalizes and
//  de-duplicates the fields.
//

import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ImageIO)
import ImageIO
#endif

public enum DocumentParser {

    /// Parse already-recognized OCR text lines (in reading order) into a result.
    /// This is pure and synchronous — ideal for unit tests and for callers that
    /// run their own OCR. Pass `expecting:` to record the caller-declared type
    /// (manual mode) so `matchesExpectedType` is populated.
    public static func parse(recognizedLines lines: [String],
                             expecting expectedType: DocumentKind? = nil) -> ScannedDocument {
        let mrz = MRZParser.firstValid(in: lines)
        let c = DocumentClassifier.classify(lines: lines, mrz: mrz)

        // In manual mode, if the detector is unsure, trust the caller's choice —
        // extract as that type rather than falling back to "unknown" (or the
        // wrong family). A confident detection of a *different* type still wins,
        // so the mismatch prompt can fire.
        let kind = (c.kind == .unknown ? expectedType : nil) ?? c.kind

        var fields: [ScannedField] = []
        var seen = Set<ScannedFieldKey>()
        func add(_ field: ScannedField) {
            guard !field.value.isEmpty, seen.insert(field.key).inserted else { return }
            fields.append(field)
        }

        if kind == .bankCheque, let cheque = ChequeParser.parse(lines) {
            cheque.scannedFields().forEach(add)
        } else {
            // MRZ fields first — most reliable.
            if let m = mrz {
                add(.init(key: .documentSubtype, label: "MRZ Type", value: m.documentType, category: .document, confidence: 0.98))
                add(.init(key: .surname, label: "Surname", value: m.surname, category: .personal, confidence: 0.98))
                add(.init(key: .givenNames, label: "Given Names", value: m.givenNames, category: .personal, confidence: 0.98))
                add(.init(key: .documentNumber, label: "Document No", value: m.documentNumber, category: .document, confidence: 0.98))
                add(.init(key: .nationalityCode, label: "Nationality (code)", value: m.nationality, category: .personal, confidence: 0.98))
                add(.init(key: .issuingCountry, label: "Issuing Country", value: m.issuingCountry, category: .document, confidence: 0.98))
                add(.init(key: .dateOfBirth, label: "Date of Birth", value: formatMRZDate(m.dateOfBirth), category: .personal, confidence: 0.98))
                add(.init(key: .sex, label: "Sex", value: m.sex.replacingOccurrences(of: "<", with: ""), category: .personal, confidence: 0.98))
                add(.init(key: .dateOfExpiry, label: "Expiry", value: formatMRZDate(m.expiryDate), category: .document, confidence: 0.98))
                if !m.optionalData.isEmpty {
                    add(.init(key: .optionalData, label: "Optional Data", value: m.optionalData, category: .document, confidence: 0.98))
                }
                // A UAE TD1 carries the Emirates ID number in the optional area.
                if let eid = emiratesIDNumber(fromMRZOptional: m.optionalData) {
                    add(.init(key: .emiratesIDNumber, label: "ID Number", value: eid, category: .document, confidence: 0.98))
                }
            }
            // Then labeled fields from the free text — but the checksummed MRZ
            // is authoritative: OCR must never supply a value the MRZ already
            // answered, under its own key or a lookalike (fullName, cardNumber).
            let mrzOwned: Set<ScannedFieldKey> = mrz == nil ? [] :
                [.surname, .givenNames, .fullName, .documentNumber, .cardNumber,
                 .passportNumber, .nationalityCode, .nationality, .issuingCountry,
                 .dateOfBirth, .sex, .dateOfExpiry]
            FieldExtractor.extract(from: lines)
                .filter { !mrzOwned.contains($0.key) }
                .forEach(add)

            // Emirates ID fronts often print the holder's family name as a
            // separate value beside the generic "Name" label. Preserve it so
            // the host can combine it with the second given name, like MRZ.
            if kind == .emiratesIDFront, !seen.contains(.surname),
               let surname = emiratesIDSurname(in: lines) {
                add(.init(key: .surname, label: "Surname", value: surname,
                          category: .personal, confidence: 0.8))
            }

            // Loose dates only when nothing labeled a date.
            let labeledDate = seen.contains(.dateOfBirth) || seen.contains(.dateOfIssue) || seen.contains(.dateOfExpiry)
            if !labeledDate {
                for d in TextNormalization.detectDates(in: lines.joined(separator: "\n")) {
                    add(.init(key: .detectedDate, label: "Date found", value: d, category: .other, confidence: 0.6))
                }
            }
        }

        // On a trade licence the "License No" belongs to the business, not a
        // vehicle — re-home the field the generic licence spec extracted.
        if kind == .tradeLicense, let i = fields.firstIndex(where: { $0.key == .licenseNumber }) {
            let f = fields[i]
            fields[i] = ScannedField(key: .licenseNumber, label: "License No",
                                     value: f.value, category: .business,
                                     confidence: f.confidence)
        }

        return ScannedDocument(
            documentType: kind,
            confidence: c.confidence,
            classificationSignals: c.reasons,
            fields: fields,
            mrz: mrz,
            rawText: lines,
            expectedType: expectedType
        )
    }

    /// The Emirates ID number hides in a TD1's optional data as 15 digits
    /// starting 784; format it in the printed 784-YYYY-NNNNNNN-C grouping.
    static func emiratesIDNumber(fromMRZOptional optional: String) -> String? {
        guard optional.count == 15, optional.hasPrefix("784"),
              optional.allSatisfy(\.isNumber) else { return nil }
        let s = Array(optional)
        return "784-\(String(s[3..<7]))-\(String(s[7..<14]))-\(String(s[14]))"
    }

    private static func emiratesIDSurname(in lines: [String]) -> String? {
        guard let labelIndex = lines.firstIndex(where: {
            let label = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label == "name" || label == "name:"
        }) else { return nil }

        for line in lines.dropFirst(labelIndex + 1).prefix(3) {
            let value = TextNormalization.sanitizeValue(line)
            guard value.rangeOfCharacter(from: .letters) != nil,
                  value.components(separatedBy: " ").count <= 3 else { continue }
            let lower = value.lowercased()
            guard !lower.contains("date"), !lower.contains("nationality"),
                  !lower.contains("expiry"), !lower.contains("issuing") else { continue }
            return value
        }
        return nil
    }

    /// YYMMDD → "dd MMM yyyy" using the ICAO century window (>=50 ⇒ 1900s).
    static func formatMRZDate(_ yymmdd: String) -> String {
        guard yymmdd.count == 6, let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)), let dd = Int(yymmdd.suffix(2)) else { return yymmdd }
        var comps = DateComponents()
        comps.year = yy >= 50 ? 1900 + yy : 2000 + yy
        comps.month = mm; comps.day = dd
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return yymmdd }
        let f = DateFormatter(); f.dateFormat = "dd MMM yyyy"
        return f.string(from: date)
    }

    #if canImport(Vision)
    /// Run text recognition over a `CGImage` and parse the result. Use this when
    /// the caller already has an image (gallery pick, file, server frame) rather
    /// than the live camera. The image is perspective-corrected and cropped to
    /// the document first, which markedly improves recognition of handwriting
    /// and small print on angled photos. English + Arabic where supported.
    /// Parse an image. The document is rectified, then OCR runs as two passes —
    /// a plain crop (sharp for printed text: numbers, branch, date) and an
    /// enhanced crop (grayscale/contrast/upscale for faint handwriting). Each
    /// pass is parsed independently (so per-pass layout is preserved) and the
    /// two results are merged: printed fields come from the plain pass, the
    /// handwritten payee from whichever pass read it more completely.
    public static func parse(image: CGImage,
                             orientation: CGImagePropertyOrientation = .up,
                             expecting expectedType: DocumentKind? = nil) throws -> ScannedDocument {
        if let pair = ImageRectifier.rectifiedImages(image, orientation: orientation) {
            return parse(rectified: pair, original: image, orientation: orientation,
                         expecting: expectedType)
        }
        return parseFlat(image: image, orientation: orientation, expecting: expectedType)
    }

    /// Parse an already-rectified render pair (the camera scanner rectifies
    /// eagerly so it can hand the cropped image to its caller before parsing).
    /// `original` is the un-resampled source frame — the sharpest pixels there
    /// are, used as a further chance when the rectified renders' MICR band
    /// won't decode (perspective resampling softens glyph strokes).
    static func parse(rectified pair: (plain: CGImage, enhanced: CGImage),
                      original: CGImage? = nil,
                      orientation: CGImagePropertyOrientation = .up,
                      expecting expectedType: DocumentKind? = nil) -> ScannedDocument {
        let plainObs = recognizeObservations(pair.plain, orientation: .up)
        let enhancedObs = recognizeObservations(pair.enhanced, orientation: .up)
        let plain = parse(recognizedLines: plainObs.map(\.text), expecting: expectedType)
        let enhanced = parse(recognizedLines: enhancedObs.map(\.text), expecting: expectedType)
        var doc = merge(primary: plain, secondary: enhanced)
        if doc.documentType == .bankCheque {
            // The enhanced render (upscaled, contrast-boosted) is the second
            // chance for bands whose plain crop is too small or too faint; the
            // original frame (OCR'd lazily, only when needed) is the last.
            doc = applyingDecodedMICR(to: doc,
                                      attempts: [(pair.plain, plainObs),
                                                 (pair.enhanced, enhancedObs)],
                                      lastResort: original.flatMap { orientedCGImage($0, orientation) })
        }
        doc.image = jpegData(pair.plain)
        return doc
    }

    /// No document quad (flat scans, screenshots): parse the frame as-is,
    /// still re-reading the MICR band from pixels when one shows up.
    static func parseFlat(image: CGImage, orientation: CGImagePropertyOrientation,
                          expecting expectedType: DocumentKind? = nil) -> ScannedDocument {
        let obs = recognizeObservations(image, orientation: orientation)
        var doc = parse(recognizedLines: obs.map(\.text), expecting: expectedType)
        let oriented = orientedCGImage(image, orientation)
        if doc.documentType == .bankCheque, let oriented {
            doc = applyingDecodedMICR(to: doc, attempts: [(oriented, obs)], lastResort: nil)
        }
        doc.image = oriented.flatMap(jpegData)
        return doc
    }

    /// Re-attempt only the MICR band decode on a fresh frame (the scanner's
    /// backup still — focus and motion vary frame to frame), merging the
    /// decoded fields into an existing result. No-op when the first parse
    /// already decoded the band.
    static func retryingMICR(_ doc: ScannedDocument, with image: CGImage,
                             orientation: CGImagePropertyOrientation) -> ScannedDocument {
        guard doc.documentType == .bankCheque, doc[.receiptNumber] == nil else { return doc }
        if let pair = ImageRectifier.rectifiedImages(image, orientation: orientation) {
            let obs = recognizeObservations(pair.plain, orientation: .up)
            return applyingDecodedMICR(to: doc, attempts: [(pair.plain, obs)],
                                       lastResort: orientedCGImage(image, orientation))
        }
        guard let oriented = orientedCGImage(image, orientation) else { return doc }
        let obs = recognizeObservations(oriented, orientation: .up)
        return applyingDecodedMICR(to: doc, attempts: [(oriented, obs)], lastResort: nil)
    }

    /// JPEG-encode a scanned render for `ScannedDocument.image`.
    static func jpegData(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Vision reads the E-13B MICR band only approximately (dropped 1s, symbols
    /// as stray marks). When a line looked MICR-ish, re-read that band from
    /// pixels with the template-matching `MICRReader` and, on a confident
    /// decode, replace the MICR text and the fields it encodes. Each attempt is
    /// an image with its OCR observations; the first confident decode wins. A
    /// failed decode leaves the OCR-derived fields untouched.
    static func applyingDecodedMICR(to doc: ScannedDocument,
                                    attempts allAttempts: [(image: CGImage, observations: [(text: String, box: CGRect)])],
                                    lastResort: CGImage? = nil)
        -> ScannedDocument {
        var doc = doc
        var attempts = allAttempts
        var bandSeen = false
        var decoded: (text: String, confidence: Double)?
        func tryAttempts() {
            // No position gate: the crop is not always tightly the cheque —
            // a detected quad can take in the whole cheque book or the table,
            // leaving the band mid-image. The bottom-most E-13B-looking line
            // wins (observations arrive top-to-bottom).
            for attempt in attempts {
                guard let band = attempt.observations.last(where: {
                    ChequeParser.looksLikeMICR($0.text) }) else { continue }
                bandSeen = true
                decoded = MICRReader.read(document: attempt.image, lineBox: band.box)
                if decoded != nil { return }
            }
            // Vision sometimes fails to see the band as text at all. On a
            // tight crop the band is the strip along the foot — try that
            // region directly (the reader isolates the glyph rows).
            let foot = CGRect(x: 0.05, y: 0.04, width: 0.9, height: 0.09)
            for attempt in attempts where decoded == nil {
                decoded = MICRReader.read(document: attempt.image, lineBox: foot)
            }
        }
        tryAttempts()
        // The rectified renders resample pixels; the original frame doesn't.
        // OCR it only on failure — it's the sharpest source there is.
        if decoded == nil, let lastResort {
            attempts = [(lastResort, recognizeObservations(lastResort, orientation: .up))]
            tryAttempts()
        }
        guard let decoded else {
            // Say why, where integrators already look (signals are shown by
            // the sample apps and logged with logsRawText).
            doc.classificationSignals.append(bandSeen
                ? "MICR: band text seen but E-13B decode rejected — fallback OCR values kept"
                : "MICR: band not readable in this capture")
            return doc
        }
        let parsed = ChequeParser.parseE13B(decoded.text)
        // The decode must agree with what the cheque's face already told us —
        // a blurred glyph can clear the per-glyph threshold as the wrong
        // digit, and a confidently wrong routing/account is worse than none.
        // The on-us field must appear within the labelled/IBAN account number,
        // and a UAE routing number embeds the IBAN's 3-digit bank code.
        if let account = parsed.account, let known = doc[.accountNumber],
           known.count >= account.count, !known.contains(account) {
            doc.classificationSignals.append(
                "MICR: decode contradicted the account number — rejected")
            return doc
        }
        if let routing = parsed.routing, let iban = doc[.iban],
           iban.hasPrefix("AE"), iban.count >= 7,
           !routing.contains(iban.dropFirst(4).prefix(3)) {
            doc.classificationSignals.append(
                "MICR: decode contradicted the IBAN bank code — rejected")
            return doc
        }
        doc.classificationSignals.append(String(format: "MICR: E-13B decoded at %.0f%%",
                                                decoded.confidence * 100))
        // Every MICR-derived field carries the band's measured glyph-match
        // confidence, not a heuristic guess.
        func upsert(_ key: ScannedFieldKey, _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let field = ScannedField(key: key, label: label, value: value,
                                     category: .banking, confidence: decoded.confidence)
            if let i = doc.fields.firstIndex(where: { $0.key == key }) {
                doc.fields[i] = field
            } else {
                doc.fields.append(field)
            }
        }
        upsert(.micrLine, "MICR", decoded.text)
        upsert(.chequeNumber, "Cheque Number", parsed.cheque)
        upsert(.routingNumber, "Routing Number", parsed.routing)
        // Every band segment individually, plus all its digits combined in
        // band order as the receipt number.
        upsert(.micrChequeNumber, "Cheque Number (MICR)", parsed.cheque)
        upsert(.micrAccountNumber, "Account Number (MICR)", parsed.account)
        upsert(.receiptNumber, "Receipt Number", String(decoded.text.filter(\.isNumber)))
        // The label/IBAN-sourced account number is fuller (the MICR on-us field
        // often carries only its tail), so it only fills a gap.
        if doc[.accountNumber] == nil {
            upsert(.accountNumber, "Account Number", parsed.account)
        }
        return doc
    }

    /// Merge two parses of the same document. `primary` (the plain pass) wins for
    /// printed fields; missing fields are filled from `secondary`; the payee
    /// prefers the more complete reading (more words).
    static func merge(primary: ScannedDocument, secondary: ScannedDocument) -> ScannedDocument {
        var byKey: [ScannedFieldKey: ScannedField] = [:]
        var order: [ScannedFieldKey] = []
        for f in primary.fields { byKey[f.key] = f; order.append(f.key) }
        for f in secondary.fields {
            if let existing = byKey[f.key] {
                if f.key == .payeeName {
                    let fused = fuseName(primary: existing.value, secondary: f.value)
                    byKey[f.key] = ScannedField(key: .payeeName, label: existing.label,
                                                value: fused, category: .banking,
                                                confidence: existing.confidence ?? f.confidence)
                }
            } else {
                byKey[f.key] = f; order.append(f.key)
            }
        }
        let type = primary.documentType != .unknown ? primary.documentType : secondary.documentType
        return ScannedDocument(
            documentType: type,
            confidence: max(primary.confidence, secondary.confidence),
            classificationSignals: primary.documentType != .unknown ? primary.classificationSignals : secondary.classificationSignals,
            fields: order.compactMap { byKey[$0] },
            mrz: primary.mrz ?? secondary.mrz,
            rawText: primary.rawText + secondary.rawText,
            expectedType: primary.expectedType
        )
    }

    /// Fuse two OCR readings of the same handwritten name: take extra leading
    /// words from the longer reading (e.g. a first name one pass missed) and
    /// trust the primary (plain) pass for the shared tail tokens. On the sample
    /// cheque this combines enhanced "Saad …" with plain "… Bahwan" to yield the
    /// full correct name.
    static func fuseName(primary: String, secondary: String) -> String {
        let p = primary.split(separator: " ").map(String.init)
        let s = secondary.split(separator: " ").map(String.init)
        guard !p.isEmpty else { return secondary }
        guard !s.isEmpty else { return primary }
        let aligned = min(p.count, s.count)
        let longer = p.count >= s.count ? p : s
        let lead = Array(longer.prefix(longer.count - aligned))
        let tail = Array(p.suffix(aligned))     // shared tokens: trust the plain pass
        return (lead + tail).joined(separator: " ")
    }

    private static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        recognizeObservations(image, orientation: orientation).map(\.text)
    }

    /// The image with its EXIF orientation baked in, so Vision-normalized boxes
    /// (which are relative to the oriented image) can address its pixels.
    private static func orientedCGImage(_ image: CGImage,
                                        _ orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        #if canImport(CoreImage)
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(oriented, from: oriented.extent)
        #else
        return nil
        #endif
    }

    /// OCR with each line's Vision-normalized bounding box (origin bottom-left)
    /// kept, so the MICR band can be relocated in the image afterwards.
    private static func recognizeObservations(_ image: CGImage, orientation: CGImagePropertyOrientation)
        -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        var languages = ["en-US"]
        if let supported = try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: request.revision),
           let arabic = supported.first(where: { $0.hasPrefix("ar") }) {
            languages.append(arabic)
        }
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { obs -> (String, CGRect)? in
                guard let s = obs.topCandidates(1).first?.string else { return nil }
                let text = s.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : (text, obs.boundingBox)
            }
    }
    #endif
}
