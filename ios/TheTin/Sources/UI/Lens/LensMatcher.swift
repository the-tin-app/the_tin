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

    /// Pass B. Open-set identification against the whole pack.
    ///
    /// Exhaustive `Matcher.match`, deliberately NOT the early-exit `matchRanked`. `matchRanked`'s
    /// own doc comment says `rankedIds` MUST arrive in narrowing-agreement order — its early exit
    /// is only sound because the true card sits in the top tier once the name OCRs. This feature
    /// has no OCR gate, and `FingerprintStore.allCardIds` is documented "in no particular order",
    /// so an early exit here has nothing to make it safe: any candidate that clears `floor` and
    /// dominates its batch ends the search, whether or not a much better match sits later in the
    /// list. `Matcher.match` has no early exit and so nothing for candidate order to break — don't
    /// swap this back to `matchRanked` without an ordering source as strong as OCR narrowing.
    ///
    /// `candidateIds` defaults to the whole pack; it exists purely as a test seam (same pattern as
    /// `MultiCardDetector.forEachCell`'s `orienter` parameter) so a test can pin that the result does not
    /// depend on candidate order. No production caller passes it.
    static func identify(fingerprint: CardFingerprint, matcher: Matcher, floor: Int,
                         candidateIds: [String]? = nil) -> LensCellState {
        guard fingerprint.count > 0 else { return .noMatch }
        guard let best = (try? matcher.match(query: fingerprint,
                                             candidateIds: candidateIds ?? matcher.allCardIds))?.first,
              best.inliers >= floor else { return .noMatch }
        return .identified(cardId: best.cardId, inliers: best.inliers)
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
struct LiveLensWork: LensWork {
    let matcher: Matcher
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
        MultiCardDetector.forEachCell(in: ci, context: context) { detected in
            guard detected.plate.glareCoverage <= glareCeiling else {
                cells.append(LensCell(quad: detected.quad, state: .unreadable("reflection")))
                return
            }
            guard let fp = LensMatcher.fingerprint(detected.plate) else {
                cells.append(LensCell(quad: detected.quad, state: .unreadable("blur")))
                return
            }
            let cell = LensCell(quad: detected.quad, state: .pending)
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
        let out = cells.map { cell -> LensCell in
            guard let fp = fps[cell.id] else { return cell }
            var c = cell
            c.resolve(LensMatcher.identify(fingerprint: fp, matcher: matcher, floor: floor),
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
