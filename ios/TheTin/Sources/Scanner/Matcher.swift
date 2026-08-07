import Foundation

struct MatchCandidate: Equatable {
    let cardId: String
    let cosine: Double
    let inliers: Int
}

/// `narrow` fails this way rather than ever returning a plausible-looking but arbitrary `topK` —
/// see `Matcher.narrow`'s doc comment for why that distinction is the whole point.
enum MatcherError: Error, Equatable {
    /// The pack has no usable global vectors: the table is empty, or every row's `global_vec`
    /// failed to decode (that second case actually surfaces as `FingerprintStoreError
    /// .malformedGlobalVec`, thrown by `FingerprintStore.loadGlobalVectors` and left to propagate
    /// unwrapped — this case covers the "zero rows" shape that error can't see).
    case noGlobalVectors
}

/// Pool-confirm match path (Plan 2 Phase C): a small candidate id pool (from the OCR gate, the
/// lens's BoVW narrowing pass, or the whole pack) → geometric RANSAC verify (Plan 1
/// DescriptorMatch) → candidates ranked by inliers.
final class Matcher {
    private let store: FingerprintStore
    private let codebook: Codebook
    /// All card ids in the pack — the interim candidate pool when the OCR gate is empty.
    let allCardIds: [String]
    /// Lazily loaded, cached for the life of this instance. `Matcher` is shared with the live
    /// single-card scanner, which never narrows — loading this ~24MB matrix in `init` would tax
    /// every scan session for a matrix it never reads. Set once, by `loadedGlobalVectors()`.
    private var cachedGlobalVectors: GlobalVectors?

    init(store: FingerprintStore, codebook: Codebook) throws {
        self.store = store
        self.codebook = codebook
        self.allCardIds = try store.allCardIds()
    }

    /// Cheap bag-of-visual-words narrowing pass (Plan 2 Phase E): scores the query's global
    /// vector against every reference vector in the pack by cosine similarity and returns the
    /// `topK` best ids, best-first. Intended as the first stage ahead of `match`'s exhaustive
    /// RANSAC — a dot product per card instead of a geometric solve per card is what makes
    /// open-set identification against the whole ~23k-card pack affordable at all.
    ///
    /// ⚠️ Throws `MatcherError.noGlobalVectors` — or lets `FingerprintStoreError
    /// .malformedGlobalVec` propagate — rather than ever returning an arbitrary `topK` when the
    /// pack's vectors are absent, empty, or malformed. A silent fallback here (e.g. "just return
    /// the first topK ids") would look exactly like a working narrow pass while actually matching
    /// against a near-random handful of cards — indistinguishable from correct until the one card
    /// it happens to drop is the one being tested. Callers MUST treat either error as a hard
    /// failure of this pass, never as "no match found".
    func narrow(query: CardFingerprint, topK: Int) throws -> [String] {
        let gv = try loadedGlobalVectors()
        let qvec = VisualFingerprint.globalVector(descriptors: query.descriptors, codebook: codebook)
        var scored: [(id: String, score: Double)] = []
        scored.reserveCapacity(gv.ids.count)
        for i in 0..<gv.ids.count {
            let start = i * gv.dim
            // ArraySlice, not Array(...) — shares storage with `gv.matrix` instead of copying
            // 1KB per row across ~23k rows on every single-card narrow call.
            let score = VisualFingerprint.cosine(qvec, gv.matrix[start..<start + gv.dim])
            scored.append((gv.ids[i], score))
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(topK).map(\.id)
    }

    private func loadedGlobalVectors() throws -> GlobalVectors {
        if let cached = cachedGlobalVectors { return cached }
        let gv = try store.loadGlobalVectors()
        guard !gv.ids.isEmpty else { throw MatcherError.noGlobalVectors }
        cachedGlobalVectors = gv
        return gv
    }

    /// RANSAC-verify a candidate id pool directly (no global-NN).
    /// Unknown / null-imageBase ids (no fingerprint row) are omitted.
    func match(query: CardFingerprint, candidateIds: [String]) throws -> [MatchCandidate] {
        var out: [MatchCandidate] = []
        for id in candidateIds {
            guard let ref = try store.cardFP(id: id) else { continue }
            let inliers = DescriptorMatch.ransacInliers(
                query, ReferenceFingerprint(keypointsXY: ref.keypointsXY, descriptors: ref.descriptors, count: ref.count))
            out.append(MatchCandidate(cardId: id, cosine: 0, inliers: inliers))
        }
        return out.sorted { $0.inliers > $1.inliers }
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
