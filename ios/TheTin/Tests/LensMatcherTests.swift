import XCTest
import GRDB
@testable import TheTin

/// Uses the same bundled fixtures as `LabeledPhotoAccuracyTests`: `labeled-pack.sqlite`
/// (38 truth ids + 50 distractors) and the `IMG_<n>.pngdata` canonical plates.
final class LensMatcherTests: XCTestCase {

    private var store: FingerprintStore!
    private var matcher: Matcher!
    private var truth: [(plate: String, cardId: String)] = []

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let packURL = try XCTUnwrap(bundle.url(forResource: "labeled-pack", withExtension: "sqlite"))
        store = try FingerprintStore(path: packURL.path)
        matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle))

        struct Label: Decodable { let plate: String; let truthIds: [String]; let condition: String }
        let labelsURL = try XCTUnwrap(bundle.url(forResource: "labels", withExtension: "json"))
        let labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: labelsURL))
        // Single-truth photos only — the ambiguous twin pools are not a useful signal here.
        truth = labels.filter { $0.truthIds.count == 1 }.map { ($0.plate, $0.truthIds[0]) }
        XCTAssertGreaterThan(truth.count, 20, "fixture set unexpectedly small")
    }

    override func tearDownWithError() throws {
        try? store.close()
        store = nil; matcher = nil; truth = []
    }

    private func fingerprint(plate name: String) throws -> CardFingerprint {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "pngdata"),
                                "missing plate fixture \(name)")
        return try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: try Data(contentsOf: url)))
    }

    /// Pass A, the true-positive case: the card IS on the wishlist and is found among a small
    /// target set.
    func testWishlistHitFindsTheWantedCard() throws {
        let sample = truth[0]
        let decoys = Array(matcher.allCardIds.filter { $0 != sample.cardId }.prefix(20))
        let wanted = Set([sample.cardId] + decoys)
        let hit = LensMatcher.wishlistHit(fingerprint: try fingerprint(plate: sample.plate),
                                          wanted: wanted, matcher: matcher, floor: 20)
        XCTAssertEqual(hit, sample.cardId)
    }

    /// Pass A, the case that decides whether this feature can send you across a shop: the card is
    /// NOT on the wishlist and must not be claimed as a hit.
    func testWishlistMissDoesNotInventAHit() throws {
        let sample = truth[0]
        let wanted = Set(matcher.allCardIds.filter { $0 != sample.cardId }.prefix(20))
        let hit = LensMatcher.wishlistHit(fingerprint: try fingerprint(plate: sample.plate),
                                          wanted: wanted, matcher: matcher, floor: 20)
        XCTAssertNil(hit, "matched \(hit ?? "-") against a wishlist that excludes the true card")
    }

    func testAnEmptyWishlistNeverHits() throws {
        let hit = LensMatcher.wishlistHit(fingerprint: try fingerprint(plate: truth[0].plate),
                                          wanted: [], matcher: matcher, floor: 20)
        XCTAssertNil(hit)
    }

    /// Pass B, open set: identify against the whole pack.
    func testIdentifyResolvesAgainstTheWholePack() throws {
        let sample = truth[0]
        let state = LensMatcher.identify(fingerprint: try fingerprint(plate: sample.plate),
                                         matcher: matcher, floor: 20)
        guard case .identified(let cardId, _) = state else {
            return XCTFail("expected .identified, got \(state)")
        }
        XCTAssertEqual(cardId, sample.cardId)
    }

    func testAFeaturelessPlateIsNoMatchNotAWrongMatch() throws {
        let blank = CardFingerprint(keypoints: [], descriptors: Data())
        XCTAssertNil(LensMatcher.wishlistHit(fingerprint: blank, wanted: Set(matcher.allCardIds),
                                             matcher: matcher, floor: 20))
        XCTAssertEqual(LensMatcher.identify(fingerprint: blank, matcher: matcher, floor: 20),
                       .noMatch)
    }

    /// Regression test (review 2026-08-06, Finding 1/2): `identify` used to call the early-exit
    /// `Matcher.matchRanked` against `matcher.allCardIds`, which is documented "in no particular
    /// order" — violating `matchRanked`'s own MUST-be-narrowing-order precondition. Prove the fix
    /// (exhaustive `Matcher.match`) doesn't depend on candidate order, using REAL data: against
    /// `IMG_1535`, `ex8-63` is a genuine spurious match (clears `floor` but is NOT the true card,
    /// which scores far higher). Put the weaker match FIRST and the true card LAST — under the old
    /// `matchRanked` code this would have stopped at the first batch and returned `ex8-63` wrongly;
    /// exhaustive search must still find the true card regardless of where it sits in the list.
    func testIdentifyFindsTheTrueCardEvenWhenAWeakerMatchIsOrderedFirst() throws {
        let sample = truth[0]
        let fp = try fingerprint(plate: sample.plate)
        let ranked = try matcher.match(query: fp, candidateIds: matcher.allCardIds)
        let winner = try XCTUnwrap(ranked.first)
        XCTAssertEqual(winner.cardId, sample.cardId, "fixture assumption: sample's own card wins exhaustively")
        let decoy = try XCTUnwrap(ranked.dropFirst().first { $0.inliers >= 20 },
                                  "fixture assumption: a second candidate also clears the floor")
        XCTAssertLessThan(decoy.inliers, winner.inliers)

        // decoy FIRST, true card LAST — the exact ordering that broke the early-exit version.
        let rest = matcher.allCardIds.filter { $0 != decoy.cardId && $0 != winner.cardId }
        let ordered = [decoy.cardId] + rest + [winner.cardId]
        let state = LensMatcher.identify(fingerprint: fp, matcher: matcher, floor: 20, candidateIds: ordered)
        guard case .identified(let cardId, _) = state else {
            return XCTFail("expected .identified, got \(state)")
        }
        XCTAssertEqual(cardId, winner.cardId)
    }

    /// Finding 3 (review 2026-08-06): the only realistic source of an ORB false positive is
    /// identical printed art shared across reprints — `labels.json`'s multi-truth-id entries exist
    /// exactly because ORB can't always separate them. `IMG_1552` photographs a Wailord that is
    /// printed identically as both `ex1-14` and `ex12-14`. Put ONLY the sibling that was NOT
    /// photographed on the wishlist and see what `wishlistHit` actually does — not presupposed.
    ///
    /// ANSWER (recorded per review instructions — decides user-facing copy): this photo scores 48
    /// inliers against the card it actually shows (`ex12-14`) but only 12 against its identical-art
    /// sibling `ex1-14` — well under `floor` (20). A different physical scan of the same printed
    /// art does NOT reliably clear the floor here. **No cross-hit** — pinned as nil, not identical
    /// to the "arbitrary unrelated decoy" case only by coincidence of this fixture, but the same
    /// outcome: copy can say "found" without a variant/printing caveat for wishlist hits, because
    /// even a genuine twin didn't produce one in the one case this fixture can test.
    func testWishlistDoesNotCrossHitAVisualTwinSiblingInThisFixture() throws {
        let plate = "IMG_1552"
        let photographed = "ex12-14"   // what this specific photo actually is (48 inliers)
        let sibling = "ex1-14"         // identical printed art, different physical scan (12 inliers)
        let fp = try fingerprint(plate: plate)

        // Pin the fixture assumption this test's comment documents, so a future fixture change
        // fails loudly here instead of silently changing what this test proves.
        let scores = try matcher.match(query: fp, candidateIds: [photographed, sibling])
        XCTAssertEqual(scores.first?.cardId, photographed)
        XCTAssertLessThan(try XCTUnwrap(scores.first { $0.cardId == sibling }).inliers, 20)

        let hit = LensMatcher.wishlistHit(fingerprint: fp, wanted: [sibling], matcher: matcher, floor: 20)
        XCTAssertNil(hit, "twin sibling should not be found — cross-print ORB score stayed below floor")
    }

    // MARK: - Matcher.narrow (Task 9b)

    /// Narrowing must keep the true card for every single-truth plate in the fixture, and its rank
    /// within the FULL cosine ranking (not just membership inside some topK) must be genuinely
    /// high — proving the order is meaningful rather than "topK happens to be bigger than the
    /// fixture". 88 cards total; a full ranking (topK == allCardIds.count) still exercises real
    /// cosine scoring and sorting, it just can't demonstrate SIZE-narrowing on its own — that is
    /// `testNarrowReturnsExactlyTopKNotEverything`'s job.
    /// Narrowing must produce a MEANINGFUL cosine ranking, not merely include every id somewhere
    /// in a topK big enough to be trivial (topK == 88 on an 88-card pack proves nothing about
    /// ordering — see this file's header note on that trap). Proven two ways against the
    /// fixture's 62 single-truth plates:
    ///
    /// 1. With topK == the whole pack, `narrow` must return every id (a correctness check on the
    ///    sort/prefix, not on ranking quality), and the true card's rank in that full ranking must
    ///    sit, on average, well above chance (chance ≈ full/2) — asserted against `full` itself so
    ///    the bound stays honest if the fixture's card count ever changes. A broken or randomized
    ///    ranking could not clear this; the measured median/mean are far inside it.
    /// 2. Recall at topK values genuinely smaller than the fixture is PRINTED, not asserted to
    ///    100% — that number is a calibration input for `LensMatcher.identify`'s `topK` default,
    ///    not a bar to clear by inflating `topK` until green (explicit task instruction).
    ///    ⚠️ Measured: it is NOT 100% at small topK on this fixture. One plate (`IMG_1540` /
    ///    `pl4-34`) ranks 80th of 88 by cosine — worse than most distractors for its OWN true
    ///    card. Left in, not excluded: it is the fixture doing its job.
    func testNarrowingRanksTheTrueCardWellAboveChance() throws {
        let full = matcher.allCardIds.count
        var ranks: [(plate: String, cardId: String, rank: Int)] = []
        for t in truth {
            let fp = try fingerprint(plate: t.plate)
            let ranked = try matcher.narrow(query: fp, topK: full)
            XCTAssertEqual(ranked.count, full, "topK == pack size must return the whole pack")
            let idx = try XCTUnwrap(ranked.firstIndex(of: t.cardId),
                                    "narrow (topK == full pack) must return every id, incl. the true card, for \(t.plate)")
            ranks.append((t.plate, t.cardId, idx))
        }
        let sortedRanks = ranks.map(\.rank).sorted()
        let avgRank = Double(sortedRanks.reduce(0, +)) / Double(sortedRanks.count)
        let median = sortedRanks[sortedRanks.count / 2]
        let chance = Double(full) / 2
        print("NARROW full-ranking true-card rank of \(full): avg=\(avgRank) median=\(median) "
            + "max=\(sortedRanks.last ?? -1) min=\(sortedRanks.first ?? -1) n=\(sortedRanks.count) (chance≈\(chance))")
        for r in ranks.sorted(by: { $0.rank > $1.rank }).prefix(5) {
            print("NARROW worst rank: \(r.plate) (\(r.cardId)) rank=\(r.rank) of \(full)")
        }
        for k in [10, 20, 30, 50] {
            let hit = ranks.filter { $0.rank < k }.count
            print("NARROW recall @topK=\(k): \(hit)/\(ranks.count) = \(Double(hit) / Double(ranks.count))")
        }

        XCTAssertLessThan(Double(median), chance / 2,
            "median true-card rank \(median) is not meaningfully better than chance (\(chance)) — narrow's ordering looks arbitrary")
        XCTAssertLessThan(avgRank, chance / 2,
            "mean true-card rank \(avgRank) is not meaningfully better than chance (\(chance)) — narrow's ordering looks arbitrary")
    }

    /// Narrowing actually narrows: for a topK well below the fixture's 88 cards, the result is
    /// exactly `topK` ids, not the whole pack.
    func testNarrowReturnsExactlyTopKNotEverything() throws {
        let sample = truth[0]
        let fp = try fingerprint(plate: sample.plate)
        let narrowed = try matcher.narrow(query: fp, topK: 10)
        XCTAssertEqual(narrowed.count, 10)
        XCTAssertLessThan(Set(narrowed).count, matcher.allCardIds.count,
                          "narrow returned the whole pack, not a subset")
    }

    /// `identify` still resolves through the new two-stage (narrow → match) path with no
    /// `candidateIds` override — the production call shape.
    func testIdentifyResolvesThroughNarrowThenMatch() throws {
        let sample = truth[0]
        // No topK override — the exact production call shape (default topK, narrow → match).
        let state = LensMatcher.identify(fingerprint: try fingerprint(plate: sample.plate),
                                         matcher: matcher, floor: 20)
        guard case .identified(let cardId, _) = state else {
            return XCTFail("expected .identified, got \(state)")
        }
        XCTAssertEqual(cardId, sample.cardId)
    }

    /// An absent/unusable similarity index must fail LOUDLY through `identify`, not silently as
    /// `.noMatch` — `.noMatch` already means "genuine miss" and is indistinguishable from a broken
    /// pack if narrow's failure is swallowed into it.
    func testIdentifyReportsUnreadableWhenNarrowHasNoUsableVectors() throws {
        let broken = try Self.storeWithZeroFingerprintRows()
        defer { try? broken.close() }
        let brokenMatcher = try Matcher(store: broken, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let state = LensMatcher.identify(fingerprint: try fingerprint(plate: truth[0].plate),
                                         matcher: brokenMatcher, floor: 20)
        guard case .unreadable = state else {
            return XCTFail("expected .unreadable (loud failure), got \(state) — a broken pack must never read as a plain miss")
        }
    }

    private static func storeWithZeroFingerprintRows() throws -> FingerprintStore {
        let path = NSTemporaryDirectory() + "fp-empty-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE card_fp(card_id TEXT PRIMARY KEY, fp_version INTEGER, global_vec BLOB,
                                  kp_count INTEGER, keypoints BLOB, descriptors BLOB);
            """)
        }
        try q.close()
        return try FingerprintStore(path: path)
    }
}
