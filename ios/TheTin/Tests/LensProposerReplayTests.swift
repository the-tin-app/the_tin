import XCTest
import CoreImage
@testable import TheTin

/// Task 10 — measures THREE candidate proposers on the SAME cells cut from the same real
/// photographs, so the comparison is not against yesterday's (non-deterministic) detection run:
///
///   1. the global visual-word vector (`Matcher.narrow`) — today's proposer, the 35.4% @ top-300,
///   2. the OCR gate (`TextGate.extract` → `CandidateIndex.pool`) — the live single-card scanner's
///      proposer, never before tried on a cell cut out of a multi-card photo,
///   3. Apple's `VNGenerateImageFeaturePrintRequest` — measured OFFLINE from the plate PNGs this
///      harness dumps, because it needs ~3,000 downloaded reference images that have no business
///      inside a test bundle.
///
/// ⚠️ **MEASUREMENT, not a gate.** It asserts nothing about accuracy. Every threshold is the
/// production default, unchanged: `floor` 20, `glareCeiling` 0.5, `topK` 300,
/// `minShortSideFraction` 0.04, `maxCards` 48, `.accurate` OCR, `pool()`'s 160 cap.
///
/// `wishlistHit` + `identify` are kept ONLY because `lens-analysis.py`'s wall slot-mapping fits its
/// perspective grid against them as anchors; dropping them would make wall cells unmappable.
///
/// ```
/// TEST_RUNNER_TIN_LENS_DIR=…/docs/images/103_images \
/// TEST_RUNNER_TIN_LENS_PACK=…/fingerprints-globalvec.sqlite \
/// TEST_RUNNER_TIN_LENS_CATALOG=…/casual-v35.sqlite \
/// TEST_RUNNER_TIN_LENS_PLATES=/tmp/lens-plates \
/// TEST_RUNNER_TIN_LENS_OUT=/tmp/lens-run2/binder_1.json \
/// TEST_RUNNER_TIN_LENS_IMAGES=binder_1 \
/// xcodebuild test-without-building …
/// ```
///
/// ⚠️ The `TEST_RUNNER_` prefix is required AND the variables must be in xcodebuild's shell
/// environment, not passed as xcodebuild arguments — see `LensPhotoReplayTests`' header, which
/// paid for that lesson. A skip reads as a pass; the run is only trustworthy if TIN_LENS_OUT exists.
final class LensProposerReplayTests: XCTestCase {

    private struct CellOut: Encodable {
        let cx: Double, cy: Double, w: Double, h: Double
        let quadConfidence: Double, glare: Double, focus: Double
        let fpCount: Int
        let unreadable: String?
        let wishlistHit: String?      // anchor for wall slot-mapping only
        let identifiedId: String?     // anchor for wall slot-mapping only
        let inliers: Int?
        /// Proposer 1: truth id → rank in the FULL 23,140-long `narrow` ordering.
        let truthRanks: [String: Int]
        /// Proposer 2: the real OCR gate.
        let ocrText: String
        let numerators: [String]
        let denominator: String?
        let hp: Int?
        let ocrMs: Double
        let poolMs: Double
        let poolSize: Int
        let poolRanks: [String: Int]  // truth id → 0-based rank inside the pool
        let poolHead: [String]
        /// Proposer 3 input: the plate PNG this cell was measured from.
        let plate: String
    }

    private struct ImageOut: Encodable {
        let image: String
        let pixelWidth: Int, pixelHeight: Int
        let detectMs: Double, passAMs: Double, narrowMs: Double, matchMs: Double
        let ocrTotalMs: Double, poolTotalMs: Double
        let cells: [CellOut]
    }

    private struct Label: Decodable {
        let image: String, slot: Int
        let empty: Bool?, name: String?, cardIds: [String]?
    }
    private struct LabelFile: Decodable { let entries: [Label] }

    func testProposersAgainstRealPhotographs() throws {
        let env = ProcessInfo.processInfo.environment
        print("[proposer] env keys: "
              + env.keys.filter { $0.contains("TIN_") }.sorted().joined(separator: ","))
        guard let dirPath = env["TIN_LENS_DIR"], let packPath = env["TIN_LENS_PACK"],
              let catalogPath = env["TIN_LENS_CATALOG"], let outPath = env["TIN_LENS_OUT"],
              let platesPath = env["TIN_LENS_PLATES"] else {
            throw XCTSkip("Set TIN_LENS_DIR / _PACK / _CATALOG / _PLATES / _OUT (TEST_RUNNER_-prefixed).")
        }
        let dir = URL(fileURLWithPath: dirPath)
        let plates = URL(fileURLWithPath: platesPath)
        try? FileManager.default.createDirectory(at: plates, withIntermediateDirectories: true)

        let labels = try JSONDecoder().decode(
            LabelFile.self,
            from: try Data(contentsOf: dir.appendingPathComponent("lens-labels.json"))).entries
        var truthByImage: [String: Set<String>] = [:]
        for l in labels where l.empty != true {
            truthByImage[l.image, default: []].formUnion(l.cardIds ?? [])
        }
        let wanted = Set(try JSONDecoder().decode(
            [String].self, from: try Data(contentsOf: dir.appendingPathComponent("lens-wishlist.json"))))

        let store = try FingerprintStore(path: packPath)
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let packSize = matcher.allCardIds.count

        // GRDB opens WAL — work on a copy so the scratch catalog is never mutated under us.
        let catalogCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-catalog-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: catalogPath), to: catalogCopy)
        let catalog = try CatalogStore(path: catalogCopy.path)
        defer { try? catalog.close(); try? FileManager.default.removeItem(at: catalogCopy) }
        let t0 = Date()
        let index = try CandidateIndex(store: catalog)
        print("[proposer] pack \(packSize) cards, catalog \(try catalog.cardCount()) cards, "
              + "CandidateIndex built in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

        let only = env["TIN_LENS_IMAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let images = truthByImage.keys.sorted().filter { only?.contains($0) ?? true }
        XCTAssertFalse(images.isEmpty, "TIN_LENS_IMAGES matched no labelled image")

        var out: [ImageOut] = []
        for name in images {
            try autoreleasepool {
                out.append(try measure(image: name, dir: dir, plates: plates, matcher: matcher,
                                       packSize: packSize, index: index,
                                       truth: truthByImage[name] ?? [], wanted: wanted))
            }
        }
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: outURL)
        print("[proposer] wrote \(outPath)")
    }

    private func measure(image name: String, dir: URL, plates: URL, matcher: Matcher,
                         packSize: Int, index: CandidateIndex,
                         truth: Set<String>, wanted: Set<String>) throws -> ImageOut {
        let ci = try XCTUnwrap(CIImage(contentsOf: dir.appendingPathComponent("\(name).png")))
        let ext = ci.extent
        let context = CIContext()

        var quads: [CardQuad] = []
        var glare: [Double] = [], focus: [Double] = [], conf: [Double] = []
        var fps: [CardFingerprint?] = [], unreadable: [String?] = []
        var fields: [OcrFields] = [], ocrMs: [Double] = [], plateNames: [String] = []

        let d0 = Date()
        var ocrTotal = 0.0
        MultiCardDetector.forEachCell(in: ci, context: context) { detected in
            let i = quads.count
            quads.append(detected.quad)
            glare.append(detected.plate.glareCoverage)
            focus.append(detected.plate.focus)
            conf.append(detected.plate.quadConfidence)

            // Dump the plate BEFORE anything can drop it — proposer 3 is measured from these.
            let file = "\(name)-\(i).png"
            Self.writePNG(detected.plate, to: plates.appendingPathComponent(file), context: context)
            plateNames.append(file)

            // The real OCR gate, on the real plate, production defaults.
            let o0 = Date()
            let f = TextGate.extract(plate: detected.plate)
            let ms = Date().timeIntervalSince(o0) * 1000
            ocrTotal += ms
            fields.append(f); ocrMs.append(ms)

            guard detected.plate.glareCoverage <= 0.5 else {
                fps.append(nil); unreadable.append("reflection"); return
            }
            guard let fp = LensMatcher.fingerprint(detected.plate) else {
                fps.append(nil); unreadable.append("blur"); return
            }
            fps.append(fp); unreadable.append(nil)
        }
        let detectMs = Date().timeIntervalSince(d0) * 1000 - ocrTotal

        // --- proposer 2: OCR fields → CandidateIndex.pool
        var poolTotal = 0.0
        var poolSizes: [Int] = [], poolRanks: [[String: Int]] = [], poolHeads: [[String]] = []
        for f in fields {
            let p0 = Date()
            let pool = index.pool(fields: f)
            poolTotal += Date().timeIntervalSince(p0) * 1000
            poolSizes.append(pool.count)
            var r: [String: Int] = [:]
            for (i, id) in pool.enumerated() where truth.contains(id) { r[id] = i }
            poolRanks.append(r)
            poolHeads.append(Array(pool.prefix(5)))
        }

        // --- pass A + proposer 1 + pass B, unchanged from LensPhotoReplayTests
        let t1 = Date()
        let hits: [String?] = fps.map { fp in
            guard let fp else { return nil }
            return LensMatcher.wishlistHit(fingerprint: fp, wanted: wanted, matcher: matcher, floor: 20)
        }
        let passAMs = Date().timeIntervalSince(t1) * 1000

        var narrowMs = 0.0, matchMs = 0.0
        var ranks: [[String: Int]] = [], ids: [String?] = [], inliers: [Int?] = []
        for fp in fps {
            guard let fp, fp.count > 0 else {
                ranks.append([:]); ids.append(nil); inliers.append(nil); continue
            }
            let n0 = Date()
            let ordered = try matcher.narrow(query: fp, topK: packSize)
            narrowMs += Date().timeIntervalSince(n0) * 1000
            var r: [String: Int] = [:]
            for (i, id) in ordered.enumerated() where truth.contains(id) { r[id] = i }
            ranks.append(r)

            let m0 = Date()
            let state = LensMatcher.identify(fingerprint: fp, matcher: matcher, floor: 20,
                                             candidateIds: Array(ordered.prefix(300)))
            matchMs += Date().timeIntervalSince(m0) * 1000
            if case .identified(let id, let n) = state { ids.append(id); inliers.append(n) }
            else { ids.append(nil); inliers.append(nil) }
        }

        let cells = quads.indices.map { i -> CellOut in
            let q = quads[i]
            let pts = [q.topLeft, q.topRight, q.bottomLeft, q.bottomRight]
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CellOut(
                cx: Double((xs.reduce(0, +) / 4 - ext.minX) / ext.width),
                cy: 1 - Double((ys.reduce(0, +) / 4 - ext.minY) / ext.height),
                w: Double((xs.max()! - xs.min()!) / ext.width),
                h: Double((ys.max()! - ys.min()!) / ext.height),
                quadConfidence: conf[i], glare: glare[i], focus: focus[i],
                fpCount: fps[i]?.count ?? 0, unreadable: unreadable[i],
                wishlistHit: hits[i], identifiedId: ids[i], inliers: inliers[i],
                truthRanks: ranks[i],
                ocrText: fields[i].rawText, numerators: fields[i].numerators,
                denominator: fields[i].denominator, hp: fields[i].hp,
                ocrMs: ocrMs[i], poolMs: poolTotal / Double(max(1, fields.count)),
                poolSize: poolSizes[i], poolRanks: poolRanks[i], poolHead: poolHeads[i],
                plate: plateNames[i])
        }

        print("[proposer] \(name): \(cells.count) cells, detect \(Int(detectMs)) ms, "
              + "ocr \(Int(ocrTotal)) ms, pool \(Int(poolTotal)) ms, "
              + "passA \(Int(passAMs)) ms, narrow \(Int(narrowMs)) ms, match \(Int(matchMs)) ms")
        return ImageOut(image: name, pixelWidth: Int(ext.width), pixelHeight: Int(ext.height),
                        detectMs: detectMs, passAMs: passAMs, narrowMs: narrowMs, matchMs: matchMs,
                        ocrTotalMs: ocrTotal, poolTotalMs: poolTotal, cells: cells)
    }

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
                    // ScanSession's F1 gate, minus the frame-denominated predicates a still cannot have.
                    let strong = top.inliers >= cfg.tLock
                    let separated = ratio >= cfg.ratioR
                    let consistent = cons.nameAgrees && cons.denomOk && !cons.hasTwinInPool
                    let verdict: String
                    if !strong { verdict = "noMatch" }
                    else if separated && consistent { verdict = "lock" }
                    else { verdict = "chooser" }
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

    private static func writePNG(_ plate: CanonicalFrame, to url: URL, context: CIContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: CGBitmapInfo = [.byteOrder32Little,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        guard let provider = CGDataProvider(data: plate.pixels as CFData),
              let cg = CGImage(width: plate.width, height: plate.height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: plate.bytesPerRow, space: cs,
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return }
        try? context.writePNGRepresentation(of: CIImage(cgImage: cg), to: url,
                                            format: .RGBA8, colorSpace: cs)
    }
}
