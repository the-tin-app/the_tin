import XCTest
@testable import TheTin

final class CardFingerprintTests: XCTestCase {
    // Fixture is bundled as `.pngdata` (still raw PNG bytes) rather than
    // `.png`: Xcode's built-in "Copy PNG File" build rule always runs
    // `copypng` on `.png` resources and re-encodes them into Apple's
    // proprietary CgBI chunk format for any target platform, including the
    // simulator. cv::imdecode (libpng-based) cannot parse CgBI, so the
    // fixture would silently fail to decode on device/simulator even though
    // it opens fine on a Mac. Renaming the extension keeps the build system
    // from touching the bytes; imdecode identifies PNG from its magic
    // number, not the filename.
    private func loadFixturePNG(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pngdata"))
        return try Data(contentsOf: url)
    }

    func testFingerprintHasKeypointsAnd32ByteDescriptors() throws {
        let fp = ScanFingerprinter.fingerprint(pngData: try loadFixturePNG("card_a"))
        let fpu = try XCTUnwrap(fp)
        XCTAssertGreaterThan(fpu.count, 20)
        XCTAssertEqual(fpu.descriptors.count, fpu.count * 32)
        XCTAssertEqual(fpu.keypoints.count, fpu.count)
        XCTAssertLessThanOrEqual(fpu.count, FingerprintConstants.orb.nfeatures)
    }
}
