import XCTest
@testable import TheTin

final class FingerprintParityTests: XCTestCase {
    private func url(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func devFP(_ name: String) throws -> CardFingerprint {
        // device images are bundled as `.pngdata` (Task 6: Xcode mangles `.png` → CgBI)
        try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: Data(contentsOf: url(name, "pngdata"))))
    }
    private func serverFP(_ name: String) throws -> ReferenceFingerprint {
        try ReferenceFingerprint(jsonData: Data(contentsOf: url(name, "json")))
    }
    // note: `url(...)` throws (XCTUnwrap), so both helpers above call it with `try`.

    // Device fingerprint of card A vs SERVER fingerprint of card A => strong match.
    func testDeviceMatchesServerSameCard() throws {
        let inliers = DescriptorMatch.ransacInliers(try devFP("card_a"), try serverFP("card_a"))
        XCTAssertGreaterThanOrEqual(inliers, 25, "same-card cross-side match too weak (\(inliers))")
    }

    // Device fingerprint of card A vs SERVER fingerprint of card B => weak / no match.
    func testDeviceRejectsDifferentCard() throws {
        let inliers = DescriptorMatch.ransacInliers(try devFP("card_a"), try serverFP("card_b"))
        XCTAssertLessThan(inliers, 8, "different-card cross-side match too strong (\(inliers))")
    }

    // The discrimination gap is what makes matching viable at all.
    func testDiscriminationGap() throws {
        let same = DescriptorMatch.ransacInliers(try devFP("card_a"), try serverFP("card_a"))
        let diff = DescriptorMatch.ransacInliers(try devFP("card_a"), try serverFP("card_b"))
        XCTAssertGreaterThan(same, diff * 3, "insufficient gap: same=\(same) diff=\(diff)")
    }
}
