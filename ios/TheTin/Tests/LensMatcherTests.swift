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

    func testAFeaturelessPlateIsNoMatchNotAWrongMatch() throws {
        let blank = CardFingerprint(keypoints: [], descriptors: Data())
        XCTAssertNil(LensMatcher.wishlistHit(fingerprint: blank, wanted: Set(matcher.allCardIds),
                                             matcher: matcher, floor: 20))
    }

    /// Regression test (review 2026-08-06, Finding 1/2): pass B used to call the early-exit
    /// `Matcher.matchRanked`, whose documented precondition is a narrowing-agreement-ordered pool.
    /// The OCR gate now produces exactly such a pool, but pass B still uses exhaustive
    /// `Matcher.match` — because that is the code the 63.3%/0-wrong measurement was taken through,
    /// and an early exit would change what was measured. This pins the property that makes it safe:
    /// against `IMG_1535`, `ex8-63` is a genuine spurious match that clears the floor while the true
    /// card scores far higher. With the decoy FIRST and the true card LAST — the exact ordering that
    /// broke the early-exit version — the winner must still be the true card.
    func testMatchFindsTheTrueCardEvenWhenAWeakerMatchIsOrderedFirst() throws {
        let sample = truth[0]
        let fp = try fingerprint(plate: sample.plate)
        let ranked = try matcher.match(query: fp, candidateIds: matcher.allCardIds)
        let winner = try XCTUnwrap(ranked.first)
        XCTAssertEqual(winner.cardId, sample.cardId, "fixture assumption: sample's own card wins exhaustively")
        let decoy = try XCTUnwrap(ranked.dropFirst().first { $0.inliers >= 20 },
                                  "fixture assumption: a second candidate also clears the floor")
        XCTAssertLessThan(decoy.inliers, winner.inliers)

        let rest = matcher.allCardIds.filter { $0 != decoy.cardId && $0 != winner.cardId }
        let ordered = [decoy.cardId] + rest + [winner.cardId]
        let out = try matcher.match(query: fp, candidateIds: ordered)
        let state = LensMatcher.verdict(results: out, consistency: Self.agrees)
        guard case .identified(let cardId, _) = state else {
            return XCTFail("expected .identified, got \(state)")
        }
        XCTAssertEqual(cardId, winner.cardId)
    }

    // MARK: - The lock gate (§6.2)

    /// OCR agreement that corroborates whatever the visual matcher picked — the "consistent" leg of
    /// the gate satisfied, so the other two legs are what these tests vary.
    private static let agrees = CandidateConsistency(nameAgrees: true, denomOk: true,
                                                     hasTwinInPool: false)

    private func results(_ inliers: Int...) -> [MatchCandidate] {
        inliers.enumerated().map { MatchCandidate(cardId: "card_\($0.offset)", cosine: 0,
                                                  inliers: $0.element) }
    }

    func testNothingClearingTheInlierFloorIsNoMatch() {
        XCTAssertEqual(LensMatcher.verdict(results: results(19, 3), consistency: Self.agrees), .noMatch)
        XCTAssertEqual(LensMatcher.verdict(results: [], consistency: Self.agrees), .noMatch)
    }

    func testStrongSeparatedAndCorroboratedLocks() {
        XCTAssertEqual(LensMatcher.verdict(results: results(64, 12), consistency: Self.agrees),
                       .identified(cardId: "card_0", inliers: 64))
    }

    /// A strong but UNSEPARATED match is the chooser, never a lock — two cards this close is exactly
    /// the shape of a wrong answer, and the chooser held the true card 48 times out of 48.
    func testAStrongButUnseparatedMatchGoesToTheChooser() {
        XCTAssertEqual(LensMatcher.verdict(results: results(30, 29, 28, 27, 26),
                                           consistency: Self.agrees),
                       .ambiguous(["card_0", "card_1", "card_2", "card_3"]))
    }

    /// Each consistency leg alone is enough to withhold a lock.
    ///
    /// `hasTwinInPool` was inert in production until 2026-08-07 — `card_twin` was 0 rows in every
    /// published catalog because the pairs file sat in a gitignored directory outside the pipeline's
    /// Docker build context — so it is pinned here rather than trusted. ⚠️ It fixes identical-art
    /// confusion and nothing else: the one wrong lock in the 415-cell measured fixture set was a twin
    /// case, but wrong locks seen on a real device were plainly wrong cards, not paired art, and are
    /// a separate unexplained problem (Tomas, 2026-08-07).
    func testEachOcrDisagreementWithholdsTheLock() {
        for cons in [CandidateConsistency(nameAgrees: false, denomOk: true, hasTwinInPool: false),
                     CandidateConsistency(nameAgrees: true, denomOk: false, hasTwinInPool: false),
                     CandidateConsistency(nameAgrees: true, denomOk: true, hasTwinInPool: true)] {
            XCTAssertEqual(LensMatcher.verdict(results: results(64, 12), consistency: cons),
                           .ambiguous(["card_0", "card_1"]), "\(cons)")
        }
    }

    /// A single candidate has nothing to be separated from. `max(second, 1)` makes the ratio the
    /// inlier count itself, which clears 1.3 — so one strong corroborated match locks.
    func testASoleStrongCandidateLocks() {
        XCTAssertEqual(LensMatcher.verdict(results: results(21), consistency: Self.agrees),
                       .identified(cardId: "card_0", inliers: 21))
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

}
