import XCTest
import CoreImage
@testable import TheTin

final class PixelFingerprintParityTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    func testDeviceCleanPlateStillMatchesShippedPack() throws {
        // Render card_a's source PNG to a canonical 660x920 BGRA plate via the DEVICE
        // Core Image path (the same resampling CardDetector will use), then read the
        // raw bytes straight out of the buffer (shared helper — see FingerprintTestSupport.swift).
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let (plate, stride) = TestPixelBuffer.bgraBytes(from: pb)
        let query = try XCTUnwrap(ScanFingerprinter.fingerprint(
            pixels: plate, width: 660, height: 920, bytesPerRow: stride))
        XCTAssertGreaterThan(query.count, 50, "clean plate produced too few keypoints")

        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle()); defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let results = try matcher.match(query: query, candidateIds: matcher.allCardIds)

        XCTAssertEqual(results.first?.cardId, "card_a", "device clean plate did not rank the correct card first")
        let a = try XCTUnwrap(results.first { $0.cardId == "card_a" })
        let b = try XCTUnwrap(results.first { $0.cardId == "card_b" })
        XCTAssertGreaterThanOrEqual(a.inliers, 25, "same-card inliers too weak (\(a.inliers))")
        XCTAssertLessThan(b.inliers, 8, "impostor inliers too strong (\(b.inliers))")
    }
}
