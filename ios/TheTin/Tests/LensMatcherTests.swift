import XCTest
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
}
