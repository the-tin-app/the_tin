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
    static func identify(fingerprint: CardFingerprint, matcher: Matcher, floor: Int) -> LensCellState {
        guard fingerprint.count > 0 else { return .noMatch }
        guard let best = (try? matcher.matchRanked(query: fingerprint,
                                                   rankedIds: matcher.allCardIds,
                                                   stopFloor: floor))?.first,
              best.inliers >= floor else { return .noMatch }
        return .identified(cardId: best.cardId, inliers: best.inliers)
    }
}
