import Foundation

struct MatchCandidate: Equatable {
    let cardId: String
    let cosine: Double
    let inliers: Int
}

/// Pool-confirm match path (Plan 2 Phase C): a small candidate id pool (from the OCR gate,
/// or — until Phase E narrows it further — the whole pack) → geometric RANSAC verify
/// (Plan 1 DescriptorMatch) → candidates ranked by inliers. The global-vector cosine NN scan
/// over the full catalog has been retired; `codebook`/`GlobalVectors` remain for later cleanup.
final class Matcher {
    private let store: FingerprintStore
    private let codebook: Codebook
    /// All card ids in the pack — the interim candidate pool when the OCR gate is empty.
    let allCardIds: [String]

    init(store: FingerprintStore, codebook: Codebook) throws {
        self.store = store
        self.codebook = codebook
        self.allCardIds = try store.allCardIds()
    }

    /// RANSAC-verify a candidate id pool directly (no global-NN).
    /// Unknown / null-imageBase ids (no fingerprint row) are omitted.
    /// ⚠️ **Batched read, then RANSAC across all cores.** Measured 2026-08-09 on the binder's own
    /// replay: this stage was **33.9% of the wall clock** at ~998 ms per cell, and it was doing three
    /// avoidable things — one SQLite transaction per candidate, rebuilding the query's keypoint buffer
    /// per candidate, and running up to 160 independent RANSACs on a single core.
    ///
    /// The result is unchanged: candidates keep `candidateIds` order going in, ids with no pack row are
    /// still skipped, and the sort is over identical input, so it is deterministic.
    ///
    /// Only the binder calls this. The live scanner uses `matchRanked`, whose early exit depends on
    /// evaluating in rank order and which is therefore deliberately left serial — its gate
    /// (`LabeledPhotoAccuracyTests`, 0 wrong-locks) is not put at risk by any of this.
    func match(query: CardFingerprint, candidateIds: [String]) throws -> [MatchCandidate] {
        let fps = try store.cardFPs(ids: candidateIds)
        let refs = candidateIds.compactMap { fps[$0] }
        guard !refs.isEmpty else { return [] }
        let queryXY = DescriptorMatch.queryKeypoints(query)
        var inliers = [Int](repeating: 0, count: refs.count)
        inliers.withUnsafeMutableBufferPointer { buf in
            let out = buf
            DispatchQueue.concurrentPerform(iterations: refs.count) { i in
                let r = refs[i]
                out[i] = DescriptorMatch.ransacInliers(
                    query, queryXY: queryXY,
                    ReferenceFingerprint(keypointsXY: r.keypointsXY, descriptors: r.descriptors,
                                         count: r.count))
            }
        }
        return zip(refs, inliers)
            .map { MatchCandidate(cardId: $0.cardId, cosine: 0, inliers: $1) }
            .sorted { $0.inliers > $1.inliers }
    }

    /// Early-exit variant of `match` for the live path. `rankedIds` MUST be in narrowing-
    /// agreement order (`CandidateIndex.pool` already is): the true card sits in the top tier
    /// whenever the name OCRs (98–100% measured through every plastic type). Matches in
    /// batches; at each batch boundary, stops once the best clears `stopFloor` (== the
    /// session's tLock) AND dominates the runner-up by `stopRatio` (== the session's ratioR) —
    /// exactly the evidence the lock gate needs, so matching deeper can only re-rank the tail.
    /// Safety gate: LabeledPhotoAccuracyTests (wrong-lock 0/64) runs THIS path; if early exit
    /// ever skips a truth that full matching would find, that suite fails.
    func matchRanked(query: CardFingerprint, rankedIds: [String],
                     batchSize: Int = 16, stopFloor: Int = 20, stopRatio: Double = 1.3)
        throws -> [MatchCandidate] {
        var out: [MatchCandidate] = []
        var start = 0
        while start < rankedIds.count {
            for id in rankedIds[start..<min(start + batchSize, rankedIds.count)] {
                guard let ref = try store.cardFP(id: id) else { continue }
                let inliers = DescriptorMatch.ransacInliers(
                    query, ReferenceFingerprint(keypointsXY: ref.keypointsXY,
                                                descriptors: ref.descriptors, count: ref.count))
                out.append(MatchCandidate(cardId: id, cosine: 0, inliers: inliers))
            }
            start += batchSize
            out.sort { $0.inliers > $1.inliers }
            if let best = out.first, best.inliers >= stopFloor,
               Double(best.inliers) >= stopRatio * Double(out.dropFirst().first?.inliers ?? 0) {
                return out
            }
        }
        return out
    }
}
