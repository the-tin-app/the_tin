import XCTest
import CoreImage
@testable import TheTin

/// Runs the photo-inventory lens against REAL photographs and the REAL 23,140-card fingerprint
/// pack, and writes every per-cell number to a JSON file for offline analysis.
///
/// ⚠️ **This is a MEASUREMENT harness, not a gate.** It asserts nothing about accuracy — it
/// records. Every threshold it uses (`floor`, `glareCeiling`, `topK`, `minShortSideFraction`) is
/// the production default, unchanged. Nothing here may be tuned to make a number look better;
/// the calibration pass that follows is a separate, deliberate piece of work informed by what
/// this prints.
///
/// It does NOT bundle its fixtures: the 12 photos are 24.5 MP PNGs (~275 MB) and the pack is
/// 569 MB. Both arrive by path, in the `ForYouReplayTests` style:
///
/// ```
/// TEST_RUNNER_TIN_LENS_DIR=/Users/tomasreyes/the-tin/docs/images/103_images \
/// TEST_RUNNER_TIN_LENS_PACK=~/hobby_tcg/fingerprint/.fp-output/fingerprints-globalvec.sqlite \
/// TEST_RUNNER_TIN_LENS_OUT=/tmp/lens-run/binder_1.json \
/// TEST_RUNNER_TIN_LENS_IMAGES=binder_1 \
/// xcodebuild test-without-building -project TheTin.xcodeproj -scheme TheTin \
///   -destination 'id=<sim>' -only-testing:TheTinTests/LensPhotoReplayTests
/// ```
///
/// ⚠️ **Two ways to make this skip silently, and a skip reads as a pass.** First, the
/// `TEST_RUNNER_` prefix is required — `xcodebuild` does not forward the shell environment into
/// the test process, and a bare `TIN_LENS_DIR=` never arrives. Second, and it cost a round trip
/// here: the prefixed variables must be in the **shell environment of xcodebuild**, as above.
/// Passed as xcodebuild *arguments* (`xcodebuild test … TEST_RUNNER_TIN_LENS_DIR=…`, the build-
/// setting form) they are accepted without complaint and never reach the runner. This test prints
/// the env keys it can actually see on every invocation for exactly that reason, and the run is
/// only trustworthy if `TIN_LENS_OUT` exists afterwards.
///
/// ⚠️ This duplicates `LiveLensWork`'s orchestration (detect → fingerprint → pass A → pass B)
/// rather than calling it, for one reason: `LiveLensWork` caches its fingerprints privately and
/// discards them, and the highest-value number here — where the true card ranks in the FULL
/// `narrow` ordering — needs the query fingerprint itself. Detection is non-deterministic
/// (`VNDetectDocumentSegmentationRequest`, documented in `CardRectifier`), so a second detect
/// pass would not produce the same cells. Everything that decides an outcome —
/// `MultiCardDetector.forEachCell`, `LensMatcher.fingerprint`, `.wishlistHit`, `.identify` — is
/// the production function, called with production defaults.
final class LensPhotoReplayTests: XCTestCase {

    // MARK: - Wire format (consumed by the analysis script)

    private struct CellOut: Encodable {
        let quad: [[Double]]          // TL, TR, BL, BR in source-image pixels (CoreImage y-up)
        let cx: Double, cy: Double    // centroid, normalised 0..1 with y measured from the TOP
        let w: Double, h: Double      // quad bounding box, normalised
        let quadConfidence: Double
        let glare: Double
        let focus: Double
        let fpCount: Int
        let unreadable: String?
        let wishlistHit: String?
        let identifiedId: String?
        let inliers: Int?
        /// truth card id → its rank (0-based) in the FULL narrow ordering over all 23,140 cards.
        /// Only the ids labelled for THIS image, which is all the analysis needs.
        let truthRanks: [String: Int]
    }

    private struct ImageOut: Encodable {
        let image: String
        let pixelWidth: Int, pixelHeight: Int
        let detectMs: Double        // Vision + rectify + fingerprint, i.e. LiveLensWork.detect
        let passAMs: Double         // wishlist match over every cell
        let narrowMs: Double        // pass B stage 1, full-ordering cosine
        let matchMs: Double         // pass B stage 2, RANSAC over the top 300
        let cells: [CellOut]
    }

    private struct Label: Decodable {
        let image: String
        let slot: Int
        let empty: Bool?
        let name: String?
        let cardIds: [String]?
    }

    private struct LabelFile: Decodable { let entries: [Label] }

    func testLensAgainstRealPhotographs() throws {
        let env = ProcessInfo.processInfo.environment
        print("[lens-replay] env keys matching TIN/RUNNER: "
              + env.keys.filter { $0.contains("TIN_") || $0.contains("RUNNER") }.sorted().joined(separator: ","))
        guard let dirPath = env["TIN_LENS_DIR"], let packPath = env["TIN_LENS_PACK"],
              let outPath = env["TIN_LENS_OUT"] else {
            throw XCTSkip("""
                Set TIN_LENS_DIR (photos + lens-labels.json + lens-wishlist.json), TIN_LENS_PACK \
                (fingerprint sqlite) and TIN_LENS_OUT (json output path) — see this file's header. \
                Pass them to xcodebuild with the TEST_RUNNER_ prefix.
                """)
        }
        let dir = URL(fileURLWithPath: dirPath)

        let labels = try JSONDecoder().decode(
            LabelFile.self,
            from: try Data(contentsOf: dir.appendingPathComponent("lens-labels.json"))).entries
        XCTAssertFalse(labels.isEmpty, "lens-labels.json decoded to nothing")

        var truthByImage: [String: Set<String>] = [:]
        for l in labels where l.empty != true {
            truthByImage[l.image, default: []].formUnion(l.cardIds ?? [])
        }

        let wanted = Set(try JSONDecoder().decode(
            [String].self, from: try Data(contentsOf: dir.appendingPathComponent("lens-wishlist.json"))))
        XCTAssertFalse(wanted.isEmpty, "lens-wishlist.json decoded to nothing")

        let store = try FingerprintStore(path: packPath)
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let packSize = matcher.allCardIds.count
        print("[lens-replay] pack \(packSize) cards, wishlist \(wanted.count) ids")

        let only = env["TIN_LENS_IMAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let images = truthByImage.keys.sorted().filter { only?.contains($0) ?? true }
        XCTAssertFalse(images.isEmpty, "TIN_LENS_IMAGES matched no labelled image")

        var out: [ImageOut] = []
        for name in images {
            try autoreleasepool {
                out.append(try measure(image: name, dir: dir, matcher: matcher, packSize: packSize,
                                       truth: truthByImage[name] ?? [], wanted: wanted))
            }
        }

        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: outURL)
        print("[lens-replay] wrote \(outPath)")
    }

    /// Control for the narrowing measurement: feed the pack a card's OWN stored descriptors and
    /// ask where `narrow` ranks it. This is the perfect-query case — if it is not rank 0, the
    /// backfilled `global_vec` column disagrees with `VisualFingerprint.globalVector`, and every
    /// narrowing number from the photographs is measuring that instead of the photographs.
    /// Prints; asserts nothing, like the rest of this file.
    func testNarrowRanksACardAgainstItsOwnDescriptors() throws {
        let env = ProcessInfo.processInfo.environment
        guard let packPath = env["TIN_LENS_PACK"] else {
            throw XCTSkip("Set TIN_LENS_PACK (TEST_RUNNER_-prefixed) — see this file's header.")
        }
        let store = try FingerprintStore(path: packPath)
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let sample = stride(from: 0, to: matcher.allCardIds.count, by: max(1, matcher.allCardIds.count / 20))
            .map { matcher.allCardIds[$0] }

        var ranks: [Int] = []
        for id in sample {
            guard let ref = try store.cardFP(id: id) else { continue }
            var kp: [SIMD2<Float>] = []
            ref.keypointsXY.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<ref.count { kp.append(SIMD2(f[i * 2], f[i * 2 + 1])) }
            }
            let q = CardFingerprint(keypoints: kp, descriptors: ref.descriptors)
            let ordered = try matcher.narrow(query: q, topK: matcher.allCardIds.count)
            ranks.append(ordered.firstIndex(of: id) ?? -1)
        }
        print("[lens-replay] self-narrow ranks over \(ranks.count) pack cards: "
              + "rank0=\(ranks.filter { $0 == 0 }.count), max=\(ranks.max() ?? -1), "
              + "all=\(ranks.sorted())")
    }

    // MARK: - One photograph

    private func measure(image name: String, dir: URL, matcher: Matcher, packSize: Int,
                         truth: Set<String>, wanted: Set<String>) throws -> ImageOut {
        let url = dir.appendingPathComponent("\(name).png")
        let ci = try XCTUnwrap(CIImage(contentsOf: url), "could not open \(url.path)")
        let ext = ci.extent
        let context = CIContext()

        // --- detect: exactly LiveLensWork.detect, production defaults, plates never accumulate.
        var quads: [CardQuad] = []
        var glare: [Double] = [], focus: [Double] = [], conf: [Double] = []
        var fps: [CardFingerprint?] = []
        var unreadable: [String?] = []
        let t0 = Date()
        MultiCardDetector.forEachCell(in: ci, context: context) { detected in
            quads.append(detected.quad)
            glare.append(detected.plate.glareCoverage)
            focus.append(detected.plate.focus)
            conf.append(detected.plate.quadConfidence)
            guard detected.plate.glareCoverage <= 0.5 else {   // LiveLensWork.glareCeiling default
                fps.append(nil); unreadable.append("reflection"); return
            }
            guard let fp = LensMatcher.fingerprint(detected.plate) else {
                fps.append(nil); unreadable.append("blur"); return
            }
            fps.append(fp); unreadable.append(nil)
        }
        let detectMs = Date().timeIntervalSince(t0) * 1000

        // --- pass A
        let t1 = Date()
        let hits: [String?] = fps.map { fp in
            guard let fp else { return nil }
            return LensMatcher.wishlistHit(fingerprint: fp, wanted: wanted, matcher: matcher, floor: 20)
        }
        let passAMs = Date().timeIntervalSince(t1) * 1000

        // --- pass B, both stages timed apart. `narrow` is asked for the WHOLE ordering so the
        // true card's rank is recoverable at any topK; `identify` is then handed the first 300 of
        // that same ordering through its documented test seam, which is bit-identical to what
        // production's `topK: 300` would have produced.
        var narrowMs = 0.0, matchMs = 0.0
        var ranks: [[String: Int]] = []
        var ids: [String?] = [], inliers: [Int?] = []
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
            let cx = xs.reduce(0, +) / 4, cy = ys.reduce(0, +) / 4
            return CellOut(
                quad: pts.map { [Double($0.x), Double($0.y)] },
                cx: Double((cx - ext.minX) / ext.width),
                // flip to y-down so the analysis script reads rows top-to-bottom like the photo
                cy: 1 - Double((cy - ext.minY) / ext.height),
                w: Double((xs.max()! - xs.min()!) / ext.width),
                h: Double((ys.max()! - ys.min()!) / ext.height),
                quadConfidence: conf[i], glare: glare[i], focus: focus[i],
                fpCount: fps[i]?.count ?? 0, unreadable: unreadable[i],
                wishlistHit: hits[i], identifiedId: ids[i], inliers: inliers[i],
                truthRanks: ranks[i])
        }

        print("[lens-replay] \(name): \(cells.count) cells, detect \(Int(detectMs)) ms, "
              + "passA \(Int(passAMs)) ms, narrow \(Int(narrowMs)) ms, match \(Int(matchMs)) ms")
        return ImageOut(image: name, pixelWidth: Int(ext.width), pixelHeight: Int(ext.height),
                        detectMs: detectMs, passAMs: passAMs, narrowMs: narrowMs, matchMs: matchMs,
                        cells: cells)
    }
}
