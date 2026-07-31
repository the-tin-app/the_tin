import Vision

// Structured fields extracted from full-plate OCR text. Kept intentionally minimal — no
// name/attackNames fields: those are matched against `rawText` (and the catalog) downstream
// in E2, not pre-extracted here.
struct OcrFields: Equatable {
    let rawText: String        // full-plate OCR, all recognized strings joined by " "
    let numerators: [String]   // deduped, first-seen order: "25","025" + promos "SWSH284" (uppercased)
    let denominator: String?   // the "/M" part, leading zeros stripped ("198")
    let hp: Int?                // first HP reading found, else nil

    /// Pure regex extraction — ported faithfully from `fingerprint/eval/scorer.py`'s
    /// `fields(text)` so it stays unit-testable without Vision.
    static func from(text: String) -> OcrFields {
        var numerators: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            if seen.insert(s).inserted { numerators.append(s) }
        }

        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var denominator: String?
        if let fracRegex = try? NSRegularExpression(pattern: #"(\d{1,3})\s*/\s*(\d{1,3})"#) {
            for m in fracRegex.matches(in: text, range: fullRange) where m.numberOfRanges == 3 {
                let a = ns.substring(with: m.range(at: 1))
                let b = ns.substring(with: m.range(at: 2))
                add(a)
                add(stripLeadingZeros(a))
                denominator = stripLeadingZeros(b)   // last match wins, as in the reference
            }
        }

        if let promoRegex = try? NSRegularExpression(pattern: #"\b([A-Z]{2,4})\s?(\d{1,3})\b"#) {
            for m in promoRegex.matches(in: text, range: fullRange) where m.numberOfRanges == 3 {
                let letters = ns.substring(with: m.range(at: 1))
                let digits = ns.substring(with: m.range(at: 2))
                add((letters + digits).uppercased())
            }
        }

        var hp: Int?
        if let prefixRegex = try? NSRegularExpression(pattern: #"HP\s*[:.]?\s*(\d{2,3})"#),
           let m = prefixRegex.firstMatch(in: text, range: fullRange), m.numberOfRanges == 2 {
            hp = Int(ns.substring(with: m.range(at: 1)))
        }
        if hp == nil,
           let suffixRegex = try? NSRegularExpression(pattern: #"(\d{2,3})\s*HP"#),
           let m = suffixRegex.firstMatch(in: text, range: fullRange), m.numberOfRanges == 2 {
            hp = Int(ns.substring(with: m.range(at: 1)))
        }

        return OcrFields(rawText: text, numerators: numerators, denominator: denominator, hp: hp)
    }

    private static func stripLeadingZeros(_ s: String) -> String {
        let stripped = s.drop { $0 == "0" }
        return stripped.isEmpty ? s : String(stripped)
    }
}

final class TextGate {
    private let index: CandidateIndex
    // ROIs on the canonical 660x920 grid, in Vision's normalized bottom-left origin.
    // Number ROI spans the FULL bottom strip: the collector number sits bottom-left on modern
    // cards but bottom-RIGHT on many older eras (DP/Platinum/EX) — a narrow left ROI misses
    // those (gate 0). CollectorNumber.parse regex-extracts the "N/M" pattern from wherever it
    // lands in the strip. Name sits along the top.
    private let numberROI = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.13)
    private let nameROI   = CGRect(x: 0.05, y: 0.86, width: 0.75, height: 0.10)
    // Full plate, used by extract(plate:) for structured field extraction (E1).
    private static let fullROI = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

    init(index: CandidateIndex) { self.index = index }

    // Superseded by extract(plate:) once F1 lands; kept unchanged in the interim — the live
    // pipeline still calls this via the C1 interim.
    func gate(plate: CanonicalFrame) -> [String] {
        guard let cg = Self.cgImage(from: plate) else { return [] }
        let number = Self.ocr(cg, roi: numberROI).flatMap(CollectorNumber.parse)
        let name = Self.ocr(cg, roi: nameROI)
        guard let number else { return [] }
        return index.candidates(number: number.number, total: number.total, name: name)
    }

    /// Full-plate OCR (orientation-tolerant) → structured OcrFields. Feeds E2's narrowing step
    /// and F1's lock gate.
    static func extract(plate: CanonicalFrame) -> OcrFields {
        guard let cg = cgImage(from: plate) else { return OcrFields.from(text: "") }
        let text = ocr(cg, roi: fullROI) ?? ""
        return OcrFields.from(text: text)
    }

    private static func ocr(_ cg: CGImage, roi: CGRect) -> String? {
        let req = VNRecognizeTextRequest()
        // `.accurate` is NOT negotiable — measured, not assumed. `.fast` was tried against the
        // 64-photo gate on 2026-07-27 and collapsed it: 21/64 auto-locks (from 51) AND a confident
        // WRONG lock, the one failure LabeledPhotoAccuracyTests calls the only one that matters.
        // Small stylized text (the collector number) is exactly what the fast path is worst at.
        req.recognitionLevel = .accurate
        // Language correction OFF: worth ~400ms of a ~2,800ms OCR on an A10, with the 64-photo
        // gate byte-identical either way (51/64, zero wrong-locks). It also stopped Vision
        // rendering HP as Cyrillic "нр"/"из".
        //
        // It is NOT the reason the OCR is slow, and the residual "BASIS"/"BASIG" for BASIC are raw
        // recognition errors that survive with correction off — do not re-blame the correction
        // pass for those. `.accurate` full-plate recognition is simply ~2,400ms on an A10, and
        // Vision runs optimized regardless of our build config, so no Release build recovers it.
        req.usesLanguageCorrection = false
        // Pin the language rather than inherit whatever the default list is — the Cyrillic in the
        // dump suggests it was considering more than en-US.
        req.recognitionLanguages = ["en-US"]
        req.regionOfInterest = roi
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return req.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private static func cgImage(from plate: CanonicalFrame) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        guard let provider = CGDataProvider(data: plate.pixels as CFData) else { return nil }
        return CGImage(width: plate.width, height: plate.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: plate.bytesPerRow, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
