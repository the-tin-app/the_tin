import XCTest
import CoreImage
import CoreVideo
@testable import TheTin

final class MatcherTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    private func openStore() throws -> FingerprintStore {
        let src = try XCTUnwrap(bundle().url(forResource: "fingerprints-fixture", withExtension: "sqlite"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        try FileManager.default.copyItem(at: src, to: tmp)
        return try FingerprintStore(path: tmp.path)
    }

    private func deviceCardA() throws -> CardFingerprint {
        let url = try XCTUnwrap(bundle().url(forResource: "card_a", withExtension: "pngdata"))
        return try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: try Data(contentsOf: url)))
    }

    func testRanksCorrectCardFirstAndRejectsOther() throws {
        let store = try openStore(); defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let results = try matcher.match(query: try deviceCardA(), candidateIds: matcher.allCardIds)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.cardId, "card_a", "correct card not ranked first by inliers")

        let a = try XCTUnwrap(results.first { $0.cardId == "card_a" })
        let b = try XCTUnwrap(results.first { $0.cardId == "card_b" })
        XCTAssertGreaterThanOrEqual(a.inliers, 25, "same-card inliers too weak (\(a.inliers))")
        XCTAssertLessThan(b.inliers, 8, "different-card inliers too strong (\(b.inliers))")
    }

    /// labeled-pack.sqlite has 88 ids; IMG_1535's truth is ex6-58 (measured 279 inliers).
    func testMatchRankedStopsEarlyWhenTruthLeadsTheRanking() throws {
        let (matcher, query, allIds) = try Self.labeledPackMatcher(plate: "IMG_1535")
        let ranked = ["ex6-58"] + allIds.filter { $0 != "ex6-58" }
        let results = try matcher.matchRanked(query: query, rankedIds: ranked)
        XCTAssertEqual(results.first?.cardId, "ex6-58")
        XCTAssertGreaterThanOrEqual(results.first?.inliers ?? 0, 20)
        XCTAssertLessThanOrEqual(results.count, 16, "should stop after the first batch")
    }

    /// Truth ranked LAST: no distractor clears the floor, so no early exit — full pool matched,
    /// truth still wins. Early-exit must never skip the truth by stopping on a weak leader.
    func testMatchRankedExhaustsPoolWhenNothingClearsFloor() throws {
        let (matcher, query, allIds) = try Self.labeledPackMatcher(plate: "IMG_1535")
        let ranked = allIds.filter { $0 != "ex6-58" } + ["ex6-58"]
        let results = try matcher.matchRanked(query: query, rankedIds: ranked)
        XCTAssertEqual(results.first?.cardId, "ex6-58")
        XCTAssertEqual(results.count, allIds.count, "no early exit before the floor is cleared")
    }

    /// Opens the bundled labeled pack and fingerprints one fixture plate.
    private static func labeledPackMatcher(plate: String) throws -> (Matcher, CardFingerprint, [String]) {
        let bundle = Bundle(for: MatcherTests.self)
        let packURL = try XCTUnwrap(bundle.url(forResource: "labeled-pack", withExtension: "sqlite"))
        let store = try FingerprintStore(path: packURL.path)
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle))
        let pngURL = try XCTUnwrap(bundle.url(forResource: plate, withExtension: "pngdata"))
        let ci = try XCTUnwrap(CIImage(data: Data(contentsOf: pngURL)))
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, FingerprintConstants.canonW, FingerprintConstants.canonH,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = try XCTUnwrap(pb)
        CIContext().render(ci, to: buffer)
        let frame = try XCTUnwrap(CardDetector().detect(pixelBuffer: buffer))
        let query = try XCTUnwrap(ScanFingerprinter.fingerprint(
            pixels: frame.pixels, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow))
        return (matcher, query, matcher.allCardIds)
    }
}
