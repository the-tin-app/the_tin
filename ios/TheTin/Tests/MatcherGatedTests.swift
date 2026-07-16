import XCTest
@testable import TheTin

final class MatcherGatedTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    private func deviceCardA() throws -> CardFingerprint {
        let url = try XCTUnwrap(bundle().url(forResource: "card_a", withExtension: "pngdata"))
        return try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: try Data(contentsOf: url)))
    }

    func testGatedVerifyRanksCorrectAndDropsUnknownId() throws {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle()); defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let results = try matcher.match(query: try deviceCardA(), candidateIds: ["card_b", "card_a", "ghost"])

        XCTAssertEqual(results.count, 2, "unknown id 'ghost' must be dropped")
        XCTAssertEqual(results.first?.cardId, "card_a")
        XCTAssertGreaterThanOrEqual(results.first!.inliers, 25)
        XCTAssertLessThan(try XCTUnwrap(results.first { $0.cardId == "card_b" }).inliers, 8)
    }
}
