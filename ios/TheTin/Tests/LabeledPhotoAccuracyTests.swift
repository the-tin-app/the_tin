import XCTest
import CoreImage
import CoreVideo
@testable import TheTin

/// Phase G — the accuracy REGRESSION GATE: proves the production Swift pipeline (the real
/// `CardDetector` → `ScanFingerprinter` → `TextGate` → `CandidateIndex` → `Matcher` →
/// `ScanSession` types, not just the Python reference `fingerprint/eval/scorer.py`) hits zero
/// confident wrong-locks across the 64 real through-plastic photos.
///
/// It reproduces `ScanPipeline.process` exactly — detect → fingerprint → OCR → narrow →
/// confirm → per-candidate consistency → `ScanSession` lock gate — but factored so the heavy
/// per-plate work (fingerprint + full-plate `.accurate` OCR + RANSAC over the pool) runs ONCE
/// per photo instead of once per frame: the fixture plate is a static image, so re-OCRing it
/// each frame is pure waste, and driving the async `ScanPipeline.process` 6×/photo jetsam-kills
/// the sim on 64 photos. The resulting `FrameObservation` is fed to a fresh `ScanSession` the
/// few frames needed to satisfy its stability streak — the one thing that legitimately varies
/// frame-to-frame (a steady hand holding one card). This is the brief's sanctioned option 2.
///
/// Fixtures (built by `fingerprint/scripts/make_labeled_plates.py` +
/// `fingerprint/eval/make_scan_plates.swift`, see those files' headers):
///   - `labels.json` — photo -> acceptable truth card id(s) + condition. Most photos have a
///     single truth id; 4 (1542/1543/1547/1552) have several — either a name mismatch the
///     automated truth resolver couldn't pin (Articuno "ex" -> np-32) or a genuine
///     identical-art twin pool (Blastoise base1-2/base4-2/dp3-2/pl1-2; Wailord ex1-14/
///     ex12-14) where any pool member is an acceptable answer. Mirrors truth.txt + scorer.py's
///     AMBIG dict.
///   - `IMG_<num>.pngdata` — canonical 660x920 BGRA plates, PNG-encoded, produced by the
///     PRODUCTION doc-seg detect + orientation-normalize algorithm (make_scan_plates.swift
///     mirrors `CardDetector`'s `CardRectifier`/`OrientationNormalizer` 1:1). Detection is thus
///     baked in at fixture-build time (Vision-in-XCTest on 64 full-res HEIC would be slow/flaky
///     and bloat the bundle); the real `CardDetector.detect` still runs here via its documented
///     `canonicalPassthrough` branch, so it re-derives the exact same `CanonicalFrame` the
///     downstream stages consume.
///   - `labeled-pack.sqlite` — nf=650 fingerprint reference pack (FingerprintConstantsParityTests
///     guards nf=650/FP_VERSION=3 parity) for the 38 unique truth ids + 50 distractors.
///   - `labeled-catalog.sqlite` — Plan-1 catalog subset (`set_info.printed_total`, real
///     attack/ability text in `card_text.body`, `card_twin` for the two identical-art pools)
///     for the same 88 cards.
final class LabeledPhotoAccuracyTests: XCTestCase {
    private struct Label: Decodable { let plate: String; let truthIds: [String]; let condition: String }

    /// Measured on this fixture the day Phase G landed: auto-lock-ok 51/64 (80%), wrong-lock
    /// 0/64, chooser-hit 12, chooser-miss 1 — above the Plan 2 spike's ~70% auto-lock estimate
    /// (fingerprint/eval/README.md). The floor sits a few below the measured 51 to tolerate
    /// Vision OCR nondeterminism across sim/OS versions while still failing loudly on a real
    /// recall regression. The wrong-lock==0 assertion is the real gate.
    private static let autoLockFloor = 48

    func testThroughPlasticAccuracySuite() throws {
        let bundle = Bundle(for: Self.self)

        let labelsURL = try XCTUnwrap(bundle.url(forResource: "labels", withExtension: "json"))
        let labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: labelsURL))
        XCTAssertEqual(labels.count, 64, "expected the full 64-photo through-plastic set")

        let packURL = try XCTUnwrap(bundle.url(forResource: "labeled-pack", withExtension: "sqlite"))
        let fpStore = try FingerprintStore(path: packURL.path)
        defer { try? fpStore.close() }
        let matcher = try Matcher(store: fpStore, codebook: try Codebook.bundled(in: bundle))

        // CatalogStore/GRDB opens in WAL mode → copy the bundled sqlite to a writable temp
        // location first (as FixtureCatalog.swift does for the synthetic catalog fixture).
        let catalogURL = try XCTUnwrap(bundle.url(forResource: "labeled-catalog", withExtension: "sqlite"))
        let catalogCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("labeled-catalog-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: catalogURL, to: catalogCopy)
        let catalogStore = try CatalogStore(path: catalogCopy.path)
        defer { try? catalogStore.close() }
        let narrowing = try CandidateIndex(store: catalogStore)
        let detector = CardDetector()
        let ciContext = CIContext()   // shared: a per-photo CIContext leaks GPU memory → jetsam SIGKILL

        var wrongLocks: [String] = []
        var autoLockOK = 0, chooserHit = 0, chooserMiss = 0, noLock = 0

        for label in labels {
            try autoreleasepool {   // keep Vision/CoreImage memory flat across 64 photos
                let event = try classify(label: label, bundle: bundle, ciContext: ciContext,
                                         detector: detector, matcher: matcher, narrowing: narrowing)
                let truth = Set(label.truthIds)
                switch event {
                case .lock(let cardId):
                    if truth.contains(cardId) { autoLockOK += 1 }
                    else { wrongLocks.append("\(label.plate) [\(label.condition)]: locked \(cardId), truth \(label.truthIds)") }
                case .ambiguous(let ids):
                    if !truth.isDisjoint(with: Set(ids)) { chooserHit += 1 } else { chooserMiss += 1 }
                case .guide, .idle:
                    noLock += 1
                }
            }
        }

        print("ACCURACY-SUITE: auto-lock-ok \(autoLockOK)/\(labels.count), wrong-lock \(wrongLocks.count), "
              + "chooser-hit \(chooserHit), chooser-miss \(chooserMiss), no-lock \(noLock)")

        XCTAssertTrue(wrongLocks.isEmpty,
                      "confident WRONG auto-locks (must be zero — the only failure that matters):\n"
                      + wrongLocks.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(autoLockOK, Self.autoLockFloor,
            "auto-lock-ok regressed: \(autoLockOK)/\(labels.count) (floor \(Self.autoLockFloor)); "
            + "chooser-hit \(chooserHit), chooser-miss \(chooserMiss), no-lock \(noLock)")

        let chooserTotal = chooserHit + chooserMiss
        if chooserTotal > 0 {
            XCTAssertGreaterThanOrEqual(Double(chooserHit) / Double(chooserTotal), 0.5,
                "chooser validity regressed: \(chooserHit)/\(chooserTotal) contain the truth")
        }
    }

    /// Runs one photo through the production stages exactly as `ScanPipeline.process` assembles
    /// them, then drives a fresh `ScanSession` `frames` times so the stability streak can build.
    private func classify(label: Label, bundle: Bundle, ciContext: CIContext, detector: CardDetector,
                          matcher: Matcher, narrowing: CandidateNarrowing,
                          frames: Int = 4) throws -> ScanEvent {
        let pngURL = try XCTUnwrap(bundle.url(forResource: label.plate, withExtension: "pngdata"),
                                   "missing plate fixture for \(label.plate)")
        let pb = try XCTUnwrap(Self.canonicalPixelBuffer(pngData: try Data(contentsOf: pngURL), context: ciContext),
                               "\(label.plate): failed to build a canonical CVPixelBuffer")
        // Real CardDetector — its documented canonicalPassthrough branch fires for a 660x920
        // BGRA buffer and re-derives the CanonicalFrame the pipeline consumes.
        let frame = try XCTUnwrap(detector.detect(pixelBuffer: pb), "\(label.plate): detector returned nil")
        let query = try XCTUnwrap(
            ScanFingerprinter.fingerprint(pixels: frame.pixels, width: frame.width,
                                          height: frame.height, bytesPerRow: frame.bytesPerRow),
            "\(label.plate): fingerprint failed")

        let fields = TextGate.extract(plate: frame)
        let pool = narrowing.pool(fields: fields)
        let poolSet = Set(pool)
        let results = (try? matcher.matchRanked(query: query, rankedIds: pool)) ?? []
        let cons = Dictionary(results.map { ($0.cardId,
            narrowing.consistency(cardId: $0.cardId, fields: fields, pool: poolSet)) },
            uniquingKeysWith: { a, _ in a })
        let obs = FrameObservation(
            candidates: results.map { (id: $0.cardId, inliers: $0.inliers) },
            coverage: 1.0, cardPresent: true, gated: !pool.isEmpty, consistency: cons)

        let session = ScanSession()
        var event: ScanEvent = .idle
        for _ in 0..<frames {
            let e = session.ingest(obs)
            if e != .idle { event = e }
        }
        return event
    }

    /// Builds a canonical (kFPCanonW x kFPCanonH, BGRA) `CVPixelBuffer` from a PNG-encoded
    /// plate — matching production camera-frame geometry so `CardDetector.detect`'s
    /// `canonicalPassthrough` branch fires.
    private static func canonicalPixelBuffer(pngData: Data, context: CIContext) -> CVPixelBuffer? {
        guard let ci = CIImage(data: pngData) else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, FingerprintConstants.canonW, FingerprintConstants.canonH,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        context.render(ci, to: buffer)
        return buffer
    }
}
