import XCTest
import CoreImage
@testable import TheTin

/// Replays whole binder PAGES — every tile of a page, through detection, the production gate and
/// production slot assignment — and scores the result **per pocket** against hand-labelled truth.
///
/// ⚠️ This is the number the target is written in. `LensProposerReplayTests` measures cells: "of the
/// quads we detected, how many did the gate lock". That cannot see a pocket whose card was never
/// detected at all, cannot see a card placed in its neighbour's pocket, and cannot see the overlap
/// between tiles resolving (or losing) an answer. Tomas's target — *"two 3×3 pages: 14 locks, 2
/// probably, 2 choose-from-four"* — is 18 POCKETS, so 18 is what this counts.
///
/// ⚠️ **MEASUREMENT, not a gate.** It asserts only that the fixture loaded. Every threshold is the
/// production default and every decision comes from production code: `LensMatcher.verdict`,
/// `BinderPlan.place`, `BinderPlan.assign`. Nothing here re-implements a rule.
///
/// ```
/// TEST_RUNNER_TIN_BINDER_DIR=…/docs/images/binder-device-2026-08-07 \
/// TEST_RUNNER_TIN_LENS_PACK=…/fingerprints-globalvec.sqlite \
/// TEST_RUNNER_TIN_LENS_CATALOG=…/casual-v35.sqlite \
/// TEST_RUNNER_TIN_BINDER_OUT=/tmp/pockets.json \
/// xcodebuild test-without-building …
/// ```
/// `TIN_BINDER_DIR` holds `binder-truth.json` and a `diag/` (or `tiles/`) directory of
/// `<page>.<rowOffset>.<colOffset>.jpg` photographs.
final class BinderPageReplayTests: XCTestCase {

    private struct Truth: Decodable {
        struct Pocket: Decodable {
            let page: Int, row: Int, col: Int
            let cardId: String?
            let name: String?
            let absentFromCatalog: Bool?
        }
        let shape: BinderShape
        let pockets: [Pocket]
    }

    func testPerPocketAccuracyOnDevicePages() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["TIN_BINDER_DIR"], let packPath = env["TIN_LENS_PACK"],
              let catalogPath = env["TIN_LENS_CATALOG"], let outPath = env["TIN_BINDER_OUT"] else {
            throw XCTSkip("Set TIN_BINDER_DIR / TIN_LENS_PACK / TIN_LENS_CATALOG / TIN_BINDER_OUT.")
        }
        let dir = URL(fileURLWithPath: dirPath)
        let truth = try JSONDecoder().decode(
            Truth.self, from: try Data(contentsOf: dir.appendingPathComponent("binder-truth.json")))
        let shape = truth.shape
        var truthBySlot: [BinderSlot: String?] = [:]
        for p in truth.pockets {
            truthBySlot[BinderSlot(page: p.page, row: p.row, col: p.col)] = p.cardId
        }

        let store = try FingerprintStore(path: packPath)
        defer { try? store.close() }
        let matcher = try Matcher(store: store,
                                  codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let catalogCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("binder-page-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: catalogPath), to: catalogCopy)
        let catalog = try CatalogStore(path: catalogCopy.path)
        defer { try? catalog.close(); try? FileManager.default.removeItem(at: catalogCopy) }
        let index = try CandidateIndex(store: catalog)

        let pages = Set(truth.pockets.map(\.page)).sorted()
        var observations: [Obs] = []
        var assigned: [BinderSlot: Obs] = [:]

        for page in pages {
            var pageObs: [(slot: BinderSlot, score: Int, fpCount: Int, value: Obs)] = []
            for tile in BinderPlan.tiles(shape: shape, page: page) {
                guard let ci = image(named: tile.id, in: dir) else {
                    XCTFail("no photograph for tile \(tile.id)")
                    continue
                }
                var cells: [LensCell] = []
                var byCell: [UUID: Obs] = [:]
                try autoreleasepool {
                    let context = CIContext()
                    // Byte-for-byte `LiveLensWork.detect`'s pipeline: the same size window, the same
                    // glare ceiling, the same keypoint floor, in the same order.
                    MultiCardDetector.forEachCell(in: ci, context: context,
                                                  sizeWindow: .twoByTwoTile) { detected in
                        let plate = detected.plate
                        guard plate.glareCoverage <= 0.5,
                              let fp = LensMatcher.fingerprint(plate), fp.count > 0 else {
                            cells.append(LensCell(quad: detected.quad, degrees: detected.degrees,
                                                  state: .unreadable("reflection")))
                            return
                        }
                        guard fp.count >= BinderPlan.minFpCount else { return }
                        let fields = TextGate.extract(plate: plate)
                        let pool = index.pool(fields: fields)
                        var cell = LensCell(quad: detected.quad, degrees: detected.degrees,
                                            fpCount: fp.count, state: .noMatch)
                        let scored = ScoredQuad(quad: detected.quad, confidence: 1)
                        let frameShort = Double(min(ci.extent.width, ci.extent.height))
                        var obs = Obs(tile: tile.id, poolSize: pool.count, fpCount: fp.count,
                                      shortSide: Double(min(scored.size.width,
                                                            scored.size.height)) / frameShort,
                                      longSide: Double(max(scored.size.width,
                                                           scored.size.height)) / frameShort,
                                      aspect: scored.aspect,
                                      numerators: fields.numerators,
                                      denominator: fields.denominator, ocrText: fields.rawText)
                        if !pool.isEmpty,
                           let results = try? matcher.match(query: fp, candidateIds: pool),
                           let top = results.first {
                            let second = results.dropFirst().first?.inliers ?? 0
                            let cons = index.consistency(cardId: top.cardId, fields: fields,
                                                         pool: Set(pool))
                            cell.state = LensMatcher.verdict(results: results, consistency: cons)
                            obs.top1 = top.cardId
                            obs.top1Inliers = top.inliers
                            obs.top2Inliers = second
                            obs.top2 = results.dropFirst().first?.cardId
                            obs.ratio = Double(top.inliers) / Double(max(second, 1))
                            obs.nameAgrees = cons.nameAgrees
                            obs.denomOk = cons.denomOk
                            obs.twinInPool = cons.hasTwinInPool
                            obs.chooser = results.prefix(4).map(\.cardId)
                        }
                        obs.verdict = describe(cell.state)
                        cells.append(cell)
                        byCell[cell.id] = obs
                    }
                }
                // Production placement — phantom filter, sub-grid split, both shared with the device.
                for placed in BinderPlan.place(cells: cells, tile: tile, extent: ci.extent) {
                    guard var obs = byCell[placed.cell.id] else { continue }
                    obs.slot = placed.slot.id
                    obs.truth = (truthBySlot[placed.slot] ?? nil) ?? ""
                    observations.append(obs)
                    pageObs.append((slot: placed.slot, score: placed.cell.inliers,
                                    fpCount: placed.cell.fpCount, value: obs))
                }
                print("[pocket] tile \(tile.id): \(cells.count) cells")
            }
            for (slot, obs) in BinderPlan.assign(pageObs, shape: shape) { assigned[slot] = obs }
        }

        // MARK: score, per pocket
        var rows: [PocketRow] = []
        for p in truth.pockets.sorted(by: { ($0.page, $0.row, $0.col) < ($1.page, $1.row, $1.col) }) {
            let slot = BinderSlot(page: p.page, row: p.row, col: p.col)
            let won = assigned[slot]
            let mine = observations.filter { $0.slot == slot.id }
            let outcome: String
            switch won?.verdict {
            case "lock":     outcome = won?.top1 == p.cardId ? "lock" : "WRONG"
            case "chooser":  outcome = (won?.chooser ?? []).contains(where: { $0 == p.cardId })
                                        ? "chooser" : "chooserMiss"
            case "unreadable": outcome = "unreadable"
            case .some:      outcome = "noMatch"
            case nil:        outcome = "undetected"
            }
            rows.append(PocketRow(slot: slot.id, truth: p.cardId ?? "",
                                  truthName: p.name ?? "",
                                  absentFromCatalog: p.absentFromCatalog ?? false,
                                  outcome: outcome, answer: won?.top1,
                                  verdict: won?.verdict ?? "none",
                                  observations: mine))
        }

        func n(_ s: String) -> Int { rows.filter { $0.outcome == s }.count }
        print("[pocket] === \(rows.count) pockets | lock \(n("lock")) | WRONG \(n("WRONG")) "
              + "| chooser \(n("chooser")) | chooserMiss \(n("chooserMiss")) "
              + "| noMatch \(n("noMatch")) | unreadable \(n("unreadable")) "
              + "| undetected \(n("undetected"))")
        for r in rows where r.outcome != "lock" {
            print("[pocket] \(r.slot) \(r.outcome.padding(toLength: 11, withPad: " ", startingAt: 0))"
                  + " truth=\(r.truth.isEmpty ? "(uncatalogued)" : r.truth) answer=\(r.answer ?? "-")"
                  + " \(r.truthName)")
        }

        let out = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: out)
        print("[pocket] wrote \(outPath)")
    }

    /// `diag/` first — those are the full-resolution photographs. `tiles/` holds the downscaled
    /// JPEGs the UI crops from, which are NOT what the device matched against.
    private func image(named id: String, in dir: URL) -> CIImage? {
        ["diag", "tiles", ""].lazy
            .flatMap { sub in ["jpg", "jpeg", "png", "HEIC", "heic"].map { ext in
                dir.appendingPathComponent(sub).appendingPathComponent("\(id).\(ext)") } }
            .compactMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) }
            .first
    }

    private func describe(_ state: LensCellState) -> String {
        switch state {
        case .identified: return "lock"
        case .ambiguous:  return "chooser"
        case .unreadable: return "unreadable"
        case .noMatch:    return "noMatch"
        case .pending:    return "pending"
        }
    }

    private struct Obs: Encodable {
        let tile: String
        var slot: String = ""
        var truth: String = ""
        var verdict: String = "noMatch"
        let poolSize: Int, fpCount: Int
        /// The quad's own edges, as fractions of the photograph's short side — what `CardSizeWindow`
        /// judged it on. A card-sized quad measures ~0.30–0.40 short; a straddling one is wider.
        let shortSide: Double, longSide: Double, aspect: Double
        var top1: String?
        var top2: String?
        var top1Inliers: Int = 0
        var top2Inliers: Int = 0
        var ratio: Double = 0
        var nameAgrees = false, denomOk = false, twinInPool = false
        var chooser: [String] = []
        let numerators: [String]
        let denominator: String?
        let ocrText: String
    }

    private struct PocketRow: Encodable {
        let slot: String, truth: String, truthName: String
        let absentFromCatalog: Bool
        let outcome: String
        let answer: String?
        let verdict: String
        let observations: [Obs]
    }
}
