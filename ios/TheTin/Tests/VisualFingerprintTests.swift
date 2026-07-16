import XCTest
@testable import TheTin

final class VisualFingerprintTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }
    private func codebook() throws -> Codebook { try Codebook.bundled(in: bundle()) }
    private func deviceCardA() throws -> CardFingerprint {
        let url = try XCTUnwrap(bundle().url(forResource: "card_a", withExtension: "pngdata"))
        return try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: try Data(contentsOf: url)))
    }

    func testEmptyDescriptorsGivesZeroVector() throws {
        let v = VisualFingerprint.globalVector(descriptors: Data(), codebook: try codebook())
        XCTAssertEqual(v.count, FingerprintConstants.globalVecDim)
        XCTAssertTrue(v.allSatisfy { $0 == 0 })
    }

    func testVectorIsL2Normalized() throws {
        let fp = try deviceCardA()
        let v = VisualFingerprint.globalVector(descriptors: fp.descriptors, codebook: try codebook())
        XCTAssertEqual(v.count, FingerprintConstants.globalVecDim)
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 0.02, "global vector not L2-normalized (norm=\(norm))")
    }

    func testSelfCosineIsOne() throws {
        let v = VisualFingerprint.globalVector(descriptors: try deviceCardA().descriptors, codebook: try codebook())
        XCTAssertEqual(VisualFingerprint.cosine(v, v), 1.0, accuracy: 1e-6)
    }
}
