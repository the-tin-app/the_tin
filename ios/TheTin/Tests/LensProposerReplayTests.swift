import XCTest
import CoreImage
@testable import TheTin

/// Replays the OCR-gated lock rate over real photographs — the one number that decides whether
/// the virtual binder ships: not "was the true card proposed" but "does the gate then pick it".
///
/// ⚠️ **MEASUREMENT, not a gate.** It asserts nothing about accuracy. Every threshold is the
/// production default, unchanged.
///
/// ⚠️ This file used to also measure a global visual-word proposer (`Matcher.narrow`) head-to-head
/// against the OCR gate. That comparison is finished and its loser is deleted: 35.4% pool recall at
/// 3,460 ms/cell against the gate's 75.8% at 731 ms, with 34% of every answer it gave being the
/// wrong card. Do not restore it — see `LensMatcher.identify`.
final class LensProposerReplayTests: XCTestCase {

    private struct Label: Decodable {
        let image: String, slot: Int
        let empty: Bool?, name: String?, cardIds: [String]?
    }
    private struct LabelFile: Decodable { let entries: [Label] }

    // MARK: - Lock rate on the OCR-gated pool

    /// Task 10 measured whether the OCR gate *proposes* the true card (75.8%). It did NOT measure
    /// whether the lock gate then *picks* it — pool recall and lock rate are different numbers and
    /// only the second one decides whether the feature ships.
    ///
    /// This replays `ScanSession`'s real F1 gate over a single still (no voting: `stable` and
    /// `covered` need frames a photo does not have, so the applicable predicates are `strong`,
    /// `separated` and the OCR/twin consistency triple). Every threshold is the production default.
    ///
    /// ⚠️ Truth is per-IMAGE, not per-cell — `lens-labels.json` says which cards are on the page,
    /// not which pocket holds which. So "correct" means "this card is somewhere on this page",
    /// exactly as Task 8 counted its 32/17. Comparable to that number, and slightly optimistic in
    /// the same way.
    ///
    /// ⚠️ `card_twin` is 0 rows in the served catalog, so `hasTwinInPool` is inert here.
    ///
    /// ```
    /// TEST_RUNNER_TIN_LENS_DIR=…/docs/images/103_images \
    /// TEST_RUNNER_TIN_LENS_PACK=…/fingerprints-globalvec.sqlite \
    /// TEST_RUNNER_TIN_LENS_CATALOG=…/casual-v35.sqlite \
    /// TEST_RUNNER_TIN_LENS_LOCKOUT=/tmp/lockrate.json \
    /// xcodebuild test-without-building …
    /// ```
    func testLockRateOnOcrGatedPool() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["TIN_LENS_DIR"], let packPath = env["TIN_LENS_PACK"],
              let catalogPath = env["TIN_LENS_CATALOG"], let outPath = env["TIN_LENS_LOCKOUT"] else {
            throw XCTSkip("Set TIN_LENS_DIR / _PACK / _CATALOG / _LOCKOUT (TEST_RUNNER_-prefixed).")
        }
        let dir = URL(fileURLWithPath: dirPath)
        let cfg = LockConfig()

        let labels = try JSONDecoder().decode(
            LabelFile.self,
            from: try Data(contentsOf: dir.appendingPathComponent("lens-labels.json"))).entries
        var truthByImage: [String: Set<String>] = [:]
        for l in labels where l.empty != true {
            truthByImage[l.image, default: []].formUnion(l.cardIds ?? [])
        }

        let store = try FingerprintStore(path: packPath)
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))

        let catalogCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-lock-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: catalogPath), to: catalogCopy)
        let catalog = try CatalogStore(path: catalogCopy.path)
        defer { try? catalog.close(); try? FileManager.default.removeItem(at: catalogCopy) }
        let index = try CandidateIndex(store: catalog)

        let only = env["TIN_LENS_IMAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let images = truthByImage.keys.sorted().filter { only?.contains($0) ?? true }
        XCTAssertFalse(images.isEmpty, "TIN_LENS_IMAGES matched no labelled image")

        var rows: [LockRow] = []
        for name in images {
            try autoreleasepool {
                let truth = truthByImage[name] ?? []
                // The 3×3 whole-page fixtures are PNG; the 2×2 quadrant ladder is straight
                // off the phone as HEIC. Read either rather than transcode ~840 MB.
                let ci = try XCTUnwrap(["png", "HEIC", "heic"].lazy
                    .map { dir.appendingPathComponent("\(name).\($0)") }
                    .compactMap { CIImage(contentsOf: $0,
                                          options: [.applyOrientationProperty: true]) }
                    .first, "no image for \(name)")
                let context = CIContext()
                var i = 0
                MultiCardDetector.forEachCell(in: ci, context: context) { detected in
                    defer { i += 1 }
                    let plate = detected.plate
                    let q = detected.quad
                    let w = hypot(q.topRight.x - q.topLeft.x, q.topRight.y - q.topLeft.y)
                    let h = hypot(q.bottomLeft.x - q.topLeft.x, q.bottomLeft.y - q.topLeft.y)
                    let sp = Int(min(w, h))
                    let fields = TextGate.extract(plate: plate)
                    let pool = index.pool(fields: fields)

                    guard plate.glareCoverage <= 0.5, let fp = LensMatcher.fingerprint(plate),
                          fp.count > 0 else {
                        rows.append(LockRow(image: name, cell: i, verdict: "unreadable",
                                            shortSidePx: sp, poolSize: pool.count, fpCount: 0, truthInPool: false,
                                            top1: nil, top1Inliers: 0, top2Inliers: 0, ratio: 0,
                                            nameAgrees: false, denomOk: false, twinInPool: false,
                                            top1Correct: false, chooserHasTruth: false,
                                            ocrText: fields.rawText,
                                            numerators: fields.numerators,
                                            denominator: fields.denominator))
                        return
                    }
                    let truthInPool = !truth.isDisjoint(with: Set(pool))
                    guard !pool.isEmpty,
                          let results = try? matcher.match(query: fp, candidateIds: pool),
                          let top = results.first else {
                        rows.append(LockRow(image: name, cell: i, verdict: "noMatch",
                                            shortSidePx: sp, poolSize: pool.count, fpCount: fp.count,
                                            truthInPool: truthInPool,
                                            top1: nil, top1Inliers: 0, top2Inliers: 0, ratio: 0,
                                            nameAgrees: false, denomOk: false, twinInPool: false,
                                            top1Correct: false, chooserHasTruth: false,
                                            ocrText: fields.rawText,
                                            numerators: fields.numerators,
                                            denominator: fields.denominator))
                        return
                    }
                    let second = results.dropFirst().first?.inliers ?? 0
                    let ratio = Double(top.inliers) / Double(max(second, 1))
                    let cons = index.consistency(cardId: top.cardId, fields: fields,
                                                 pool: Set(pool))
                    // ⚠️ The PRODUCTION gate, called, not re-implemented. This harness used to hold
                    // its own copy of the three predicates — which is how a measurement silently
                    // stops describing the shipped code. `LensMatcher.verdict` is what pass B runs.
                    let verdict: String
                    switch LensMatcher.verdict(results: results, consistency: cons, config: cfg) {
                    case .identified: verdict = "lock"
                    case .ambiguous:  verdict = "chooser"
                    default:          verdict = "noMatch"
                    }
                    // The chooser shows four tiles — same 2×2 grid the live scanner uses.
                    let chooserIds = Set(results.prefix(4).map(\.cardId))
                    rows.append(LockRow(
                        image: name, cell: i, verdict: verdict, shortSidePx: sp, poolSize: pool.count,
                        fpCount: fp.count, truthInPool: truthInPool, top1: top.cardId,
                        top1Inliers: top.inliers, top2Inliers: second, ratio: ratio,
                        nameAgrees: cons.nameAgrees, denomOk: cons.denomOk,
                        twinInPool: cons.hasTwinInPool,
                        top1Correct: truth.contains(top.cardId),
                        chooserHasTruth: !truth.isDisjoint(with: chooserIds),
                        ocrText: fields.rawText, numerators: fields.numerators,
                        denominator: fields.denominator))
                }
                print("[lock] \(name): \(i) cells")
            }
        }

        let locks = rows.filter { $0.verdict == "lock" }
        let good = locks.filter(\.top1Correct).count
        print("[lock] === \(rows.count) cells | lock \(locks.count) "
              + "(\(good) correct / \(locks.count - good) WRONG) "
              + "| chooser \(rows.filter { $0.verdict == "chooser" }.count) "
              + "| noMatch \(rows.filter { $0.verdict == "noMatch" }.count) "
              + "| unreadable \(rows.filter { $0.verdict == "unreadable" }.count)")

        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: outURL)
        print("[lock] wrote \(outPath)")
    }

    private struct LockRow: Encodable {
        let image: String, cell: Int, verdict: String
        /// The detected card's short side in SOURCE pixels — the size/accuracy predictor.
        var shortSidePx: Int = 0
        let poolSize: Int, fpCount: Int, truthInPool: Bool
        let top1: String?, top1Inliers: Int, top2Inliers: Int, ratio: Double
        let nameAgrees: Bool, denomOk: Bool, twinInPool: Bool
        let top1Correct: Bool, chooserHasTruth: Bool
        let ocrText: String, numerators: [String], denominator: String?
    }
}
