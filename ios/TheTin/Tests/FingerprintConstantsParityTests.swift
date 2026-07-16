import XCTest
@testable import TheTin

/// Hard cross-language guard: fails CI the moment FingerprintConstants (backed
/// by FingerprintParams.h) drifts from fingerprint/fpcore/constants.py, which
/// is the source of the checked-in tests/fixtures/params.json copied here.
final class FingerprintConstantsParityTests: XCTestCase {
    private struct ORBParamsDoc: Decodable {
        let nfeatures: Int
        let scaleFactor: Double
        let nlevels: Int
        let edgeThreshold: Int
        let firstLevel: Int
        let WTA_K: Int
        let patchSize: Int
        let fastThreshold: Int
    }
    private struct ParamsDoc: Decodable {
        let fp_version: Int
        let canon_w: Int
        let canon_h: Int
        let orb: ORBParamsDoc
        let codebook_k: Int
        let global_vec_dim: Int
    }

    private func loadParams() throws -> ParamsDoc {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "params", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ParamsDoc.self, from: data)
    }

    func testConstantsMatchPythonSourceOfTruth() throws {
        let json = try loadParams()

        XCTAssertEqual(FingerprintConstants.fpVersion, json.fp_version)
        XCTAssertEqual(FingerprintConstants.canonW, json.canon_w)
        XCTAssertEqual(FingerprintConstants.canonH, json.canon_h)

        let orb = FingerprintConstants.orb
        XCTAssertEqual(orb.nfeatures, json.orb.nfeatures)
        XCTAssertEqual(orb.scaleFactor, json.orb.scaleFactor, accuracy: 1e-6)
        XCTAssertEqual(orb.nlevels, json.orb.nlevels)
        XCTAssertEqual(orb.edgeThreshold, json.orb.edgeThreshold)
        XCTAssertEqual(orb.firstLevel, json.orb.firstLevel)
        XCTAssertEqual(orb.wtaK, json.orb.WTA_K)
        XCTAssertEqual(orb.patchSize, json.orb.patchSize)
        XCTAssertEqual(orb.fastThreshold, json.orb.fastThreshold)

        XCTAssertEqual(FingerprintConstants.codebookK, json.codebook_k)
        XCTAssertEqual(FingerprintConstants.globalVecDim, json.global_vec_dim)
    }
}
