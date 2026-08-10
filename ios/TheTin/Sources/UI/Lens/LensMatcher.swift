import CoreImage
import Foundation

/// Pass A and pass B. Free functions, `nonisolated` by construction — every call runs off the
/// MainActor inside `Task.detached`.
///
/// The two passes differ only in the size of the candidate set, and that difference is the whole
/// performance argument for this feature: pass A asks "is this one of my ~120 cards?", which has
/// none of the open-set confusion that makes ordinary scanning hard, and costs proportionally less.
enum LensMatcher {

    /// Plate → ORB fingerprint. The caller drops the plate's pixels immediately afterwards.
    static func fingerprint(_ plate: CanonicalFrame) -> CardFingerprint? {
        ScanFingerprinter.fingerprint(pixels: plate.pixels, width: plate.width,
                                      height: plate.height, bytesPerRow: plate.bytesPerRow)
    }

    /// Pass A. Returns the wanted card this plate is, or nil.
    ///
    /// `floor` is the inlier threshold. It starts at the live scanner's `LockConfig.tLock` (20) and
    /// is calibrated down against real fixtures in Task 8 — a false positive here costs a glance at
    /// a case, which is far cheaper than the live scanner's cost of locking onto the wrong card.
    /// It is NOT free, though: the whole promise is "walk over there and it will be waiting".
    static func wishlistHit(fingerprint: CardFingerprint, wanted: Set<String>,
                            matcher: Matcher, floor: Int) -> String? {
        guard !wanted.isEmpty, fingerprint.count > 0 else { return nil }
        guard let best = (try? matcher.match(query: fingerprint,
                                             candidateIds: Array(wanted)))?.first else { return nil }
        return best.inliers >= floor ? best.cardId : nil
    }

    /// Pass B. Open-set identification through the **OCR gate** — the live single-card scanner's
    /// proposer, on a cell cut out of a multi-card photograph.
    ///
    /// ⚠️ This replaced a global visual-word vector (`Matcher.narrow`) that was built, shipped and
    /// then measured against 118 real cells: it kept the true card 35.4% of the time at top-300, at
    /// 3,460 ms/cell, and 34% of every answer the feature gave was the WRONG card. The OCR gate keeps
    /// it 75.8% of the time inside a ≤160 pool at 731 ms — more than twice as accurate and 4.7×
    /// cheaper, with no trade-off to weigh. **Do not restore narrowing.** The reason is physical, not
    /// incidental: appearance summaries drift under lighting, glare and blur; the geometric
    /// arrangement RANSAC verifies does not, and a printed collector number does not either. A
    /// correct number read alone gives 100% pool recall.
    ///
    /// The verdict is `ScanSession`'s F1 lock gate, minus the frame-denominated predicates — a
    /// photograph has exactly one look, so `stable` and `covered` have nothing to count:
    ///
    /// ```
    /// !strong                            -> noMatch      (nothing clears the inlier floor)
    /// strong && separated && consistent  -> identified   (measured: 0 wrong in 346 cells)
    /// otherwise                          -> ambiguous    (top 4; held the truth 48 of 48)
    /// ```
    ///
    /// Exhaustive `Matcher.match`, not the early-exit `matchRanked`: this is byte-for-byte the gate
    /// that produced the 63.3%/0-wrong measurement, and an early exit would change what is measured.
    ///
    /// ⚠️ Do not raise `CandidateIndex.pool`'s 160 cap for this. Measured 2026-08-07 at 400: the same
    /// 57 locks over the same 90 cells for ~26% more wall clock. 28 card-sized cells were pinned at
    /// the cap and 26 of them already held the true card — the proposer stopped being the bottleneck.
    static func identify(plate: CanonicalFrame, fingerprint: CardFingerprint, matcher: Matcher,
                         index: CandidateNarrowing, config: LockConfig = LockConfig()) -> LensCellState {
        guard fingerprint.count > 0 else { return .noMatch }
        let fields = TextGate.extract(plate: plate)
        let pool = index.pool(fields: fields)
        guard !pool.isEmpty,
              let results = try? matcher.match(query: fingerprint, candidateIds: pool),
              let top = results.first else { return .noMatch }
        return verdict(results: results,
                       consistency: index.consistency(cardId: top.cardId, fields: fields,
                                                      pool: Set(pool)),
                       config: config)
    }

    /// The gate itself, separated from what feeds it so the three-way table is testable without a
    /// camera, a plate or a catalog. `results` must be inlier-descending — `Matcher.match` sorts.
    static func verdict(results: [MatchCandidate], consistency: CandidateConsistency,
                        config: LockConfig = LockConfig()) -> LensCellState {
        guard let top = results.first, top.inliers >= config.tLock else { return .noMatch }
        let second = results.dropFirst().first?.inliers ?? 0
        let separated = Double(top.inliers) / Double(max(second, 1)) >= config.ratioR
        let consistent = consistency.nameAgrees && consistency.denomOk
            && !consistency.hasTwinInPool
        guard separated, consistent else { return .ambiguous(results.prefix(4).map(\.cardId)) }
        return .identified(cardId: top.cardId, inliers: top.inliers)
    }
}

/// The production `LensWork`. Every method runs off the MainActor — `LensQueue` is an actor and
/// these are called from it — and **no plate outlives the function that made it**.
///
/// ⚠️ Detection runs exactly ONCE per photo, in `detect`, and the fingerprints it produces are
/// cached for the rest of that photo's life. The obvious alternative — re-detect at the start of
/// each pass and re-fingerprint — is wrong twice over. `VNDetectDocumentSegmentationRequest` is
/// documented **in this codebase** as non-deterministic on repeated calls over the same input
/// (`CardRectifier` records five identical calls returning 0.000/0.965/0.828/0.990/0.955), so the
/// cell counts genuinely differ between passes; any "counts must agree" guard therefore makes
/// BOTH passes silently no-op and hands the user a photo where nothing was found and no reason
/// given. It also pays for full Vision detection three times per photo.
///
/// Caching fingerprints rather than plates is what makes that affordable: ~26 KB per card against
/// a plate's 2.4 MB, so a 40-card photo holds ~1 MB instead of ~97 MB. The
/// plates-must-not-accumulate constraint was always about the plates. Jetsam is uncatchable by
/// Crashlytics and has killed this app once.
///
/// ⚠️ **OCR lives in pass B, and that placement is the product.** The gate needs the plate, and the
/// plate is gone by then — so pass B rebuilds exactly one at a time from the cell's `quad` and
/// `degrees` (`MultiCardDetector.plate`). The obvious alternative, OCR inside `detect` while the
/// plate is still in hand, is cheaper by one render per cell and wrong: OCR is 731 ms/cell against
/// pass A's 250 ms, so it would put the slowest work in the FIRST stage and make every photo's
/// "is anything I want here" wait behind the previous photo's pricing detail. Same total time,
/// wishlist answers ~3× later, and that ordering is the whole reason `LensQueue` exists.
struct LiveLensWork: LensWork {
    let matcher: Matcher
    /// The OCR gate's index. Also the scanner's — one `CandidateIndex` per pack, built above the tab.
    let index: CandidateNarrowing
    let imageForPhoto: @Sendable (UUID) async -> CIImage?
    let wanted: Set<String>
    var floor: Int = 20                 // == the live scanner's LockConfig.tLock
    /// Above this glare fraction a cell is reported unreadable rather than matched badly.
    /// ponytail: 0.5 is a starting point, calibrated against real fixtures in Task 8.
    var glareCeiling: Double = 0.5
    /// Per-photo cell.id → fingerprint. Dropped when pass B, the terminal stage, finishes.
    private let cache = FingerprintCache()

    func detect(photoId: UUID) async -> [LensCell] {
        guard let ci = await imageForPhoto(photoId) else { return [] }
        let context = CIContext()
        var cells: [LensCell] = []
        var fingerprints: [UUID: CardFingerprint] = [:]
        // ⚠️ Nothing here may hold onto a plate. Streaming keeps exactly one alive: each is
        // fingerprinted (~26 KB) and released here. Collecting them first would be 2,428,800 B
        // each × up to 48 = ~117 MB resident at once — a jetsam kill on an A10, and jetsam
        // leaves no crash report at all.
        // ⚠️ `.twoByTwoTile` is passed because the binder's capture is ALWAYS two pockets by two, which
        // is what makes a card's size in the frame knowable — and that is the only thing that separates
        // one card from two side by side, whose aspect ratios are 0.716 and 0.698. See `CardSizeWindow`.
        MultiCardDetector.forEachCell(in: ci, context: context,
                                      sizeWindow: .twoByTwoTile) { detected in
            guard detected.plate.glareCoverage <= glareCeiling else {
                cells.append(LensCell(quad: detected.quad, degrees: detected.degrees,
                                      state: .unreadable("reflection")))
                return
            }
            guard let fp = LensMatcher.fingerprint(detected.plate) else {
                cells.append(LensCell(quad: detected.quad, degrees: detected.degrees,
                                      state: .unreadable("blur")))
                return
            }
            // ⚠️ Phantoms are dropped HERE, not reported as a failure, and not carried downstream.
            // ~49% of detected quads over a binder page are glare bands, empty pockets and page
            // edges, at a median 15 keypoints against a real card's 650. Dropping them halves the
            // work of both remaining passes for one comparison — and they must not become
            // `.unreadable` either, or the screen tells the user nine cards couldn't be read on a
            // page holding four.
            guard fp.count >= BinderPlan.minFpCount else { return }
            let cell = LensCell(quad: detected.quad, degrees: detected.degrees, fpCount: fp.count,
                                state: .pending)
            fingerprints[cell.id] = fp
            cells.append(cell)
        }
        // A pocket Vision returned no quad for is still a pocket, and on a CORNER there is no second
        // tile to recover it — see `BinderPlan.missingPocketQuads`. Extrapolate one from the cards that
        // were found and give it the same chance as any other cell.
        //
        // ⚠️ The keypoint floor below does NOT make this safe, and an earlier version of this comment
        // wrongly claimed it did ("a quad over a genuinely empty pocket fingerprints at ~15 keypoints").
        // Measured on device 2026-08-09: two EMPTY pockets fingerprinted at 442 and 595. The floor only
        // rejects slivers and glare bands. What keeps an empty pocket empty is `BinderPlan.place`,
        // which discards a synthesised cell that never identified — hence the flag below.
        //
        // Only cells that fingerprinted are used to read the grid. An `.unreadable` cell may be a glare
        // band rather than a card, and letting one set the median size or the row/column line would
        // move every synthesised pocket with it.
        let real = cells.filter { $0.fpCount >= BinderPlan.minFpCount }
        // A page is photographed from one side, so every card in it is the same way up. Passing the
        // resolved rotation makes `plate` skip `orientUpright`'s scoring — two renders and two Vision
        // text passes, the bulk of detection's cost.
        let degrees = Dictionary(grouping: real, by: \.degrees)
            .max { $0.value.count < $1.value.count }?.key ?? 0
        for quad in BinderPlan.missingPocketQuads(from: real.map(\.quad), extent: ci.extent) {
            // Same streaming discipline as the loop above: one plate alive, released before the next.
            guard let plate = MultiCardDetector.plate(quad: quad, in: ci, context: context,
                                                      degrees: degrees),
                  let fp = LensMatcher.fingerprint(plate),
                  fp.count >= BinderPlan.minFpCount else { continue }
            let cell = LensCell(quad: quad, degrees: degrees, fpCount: fp.count,
                                synthesized: true, state: .pending)
            fingerprints[cell.id] = fp
            cells.append(cell)
        }
        await cache.store(photoId, fingerprints)
        return cells
    }

    func passA(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        let fps = await cache.fingerprints(photoId)
        return cells.map { cell in
            guard let fp = fps[cell.id] else { return cell }
            var c = cell
            // The id is KEPT, not just tested for nil: it is what gives a pass-A hit a row, a
            // name and a price before pass B has run on any photo. See `LensCell.cardId`.
            c.wishlistCardId = LensMatcher.wishlistHit(fingerprint: fp, wanted: wanted,
                                                       matcher: matcher, floor: floor)
            c.onWishlist = c.wishlistCardId != nil
            return c
        }
    }

    func passB(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        let fps = await cache.fingerprints(photoId)
        guard let ci = await imageForPhoto(photoId) else { return cells }
        let context = CIContext()
        let out = cells.map { cell -> LensCell in
            // Same streaming discipline as `detect`: one plate alive at a time, released before the
            // next cell is rebuilt.
            guard let fp = fps[cell.id],
                  let plate = MultiCardDetector.plate(quad: cell.quad, in: ci, context: context,
                                                      degrees: cell.degrees)
            else { return cell }
            var c = cell
            c.resolve(LensMatcher.identify(plate: plate, fingerprint: fp, matcher: matcher,
                                           index: index),
                      wanted: wanted)
            return c
        }
        // Terminal stage: nothing reads this photo's fingerprints again.
        await cache.drop(photoId)
        return out
    }
}

/// Holds one photo's fingerprints between the three stages. An actor because `LensWork` is
/// `Sendable` and its methods are called from `LensQueue`'s actor context — a stored dictionary
/// on the struct could not be mutated across them.
private actor FingerprintCache {
    private var byPhoto: [UUID: [UUID: CardFingerprint]] = [:]
    func store(_ photoId: UUID, _ fps: [UUID: CardFingerprint]) { byPhoto[photoId] = fps }
    func fingerprints(_ photoId: UUID) -> [UUID: CardFingerprint] { byPhoto[photoId] ?? [:] }
    func drop(_ photoId: UUID) { byPhoto[photoId] = nil }
}
