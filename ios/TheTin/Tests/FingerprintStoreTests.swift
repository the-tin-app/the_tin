import XCTest
import GRDB
@testable import TheTin

final class FingerprintStoreTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    /// GRDB opens the artifact read-write for WAL sidecars, so copy the fixture to a temp dir.
    private func openStore() throws -> FingerprintStore {
        let src = try XCTUnwrap(bundle().url(forResource: "fingerprints-fixture", withExtension: "sqlite"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        try FileManager.default.copyItem(at: src, to: tmp)
        return try FingerprintStore(path: tmp.path)
    }

    private func shippedVec(_ name: String) throws -> [Float16] {
        struct Doc: Decodable { let card_a: [Double]; let card_b: [Double] }
        let url = try XCTUnwrap(bundle().url(forResource: "global-vec-fixture", withExtension: "json"))
        let doc = try JSONDecoder().decode(Doc.self, from: try Data(contentsOf: url))
        return (name == "card_a" ? doc.card_a : doc.card_b).map { Float16($0) }
    }

    func testMetaReadsCodebookHashAndDims() throws {
        let store = try openStore(); defer { try? store.close() }
        let meta = try XCTUnwrap(try store.meta())
        XCTAssertEqual(meta.codebookHash, FingerprintConstants.codebookSHA256)
        XCTAssertEqual(meta.canonicalW, FingerprintConstants.canonW)
        XCTAssertEqual(meta.canonicalH, FingerprintConstants.canonH)
        XCTAssertEqual(meta.fpVersion, FingerprintConstants.fpVersion)
    }

    func testCardCountIsTwo() throws {
        let store = try openStore(); defer { try? store.close() }
        XCTAssertEqual(try store.cardCount(), 2)
    }

    func testAllCardIdsReturnsFixtureIds() throws {
        let store = try openStore(); defer { try? store.close() }
        XCTAssertEqual(Set(try store.allCardIds()), Set(["card_a", "card_b"]))
    }

    func testLoadGlobalVectorsMatrix() throws {
        let store = try openStore(); defer { try? store.close() }
        let gv = try store.loadGlobalVectors()
        XCTAssertEqual(gv.ids.sorted(), ["card_a", "card_b"])
        XCTAssertEqual(gv.dim, FingerprintConstants.globalVecDim)
        XCTAssertEqual(gv.matrix.count, gv.ids.count * gv.dim)
    }

    // Closes the loop: the store decodes global_vec to the same bytes the sidecar recorded.
    func testGlobalVecDecodeMatchesSidecar() throws {
        let store = try openStore(); defer { try? store.close() }
        let decoded = try XCTUnwrap(try store.globalVec(id: "card_a"))
        XCTAssertEqual(VisualFingerprint.cosine(decoded, try shippedVec("card_a")), 1.0, accuracy: 1e-4)
    }

    func testKeypointsUnpackToCanonicalPixels() throws {
        let store = try openStore(); defer { try? store.close() }
        let fp = try XCTUnwrap(try store.cardFP(id: "card_a"))
        XCTAssertEqual(fp.count, 650)
        XCTAssertEqual(fp.descriptors.count, 650 * 32)
        XCTAssertEqual(fp.keypointsXY.count, 650 * 2 * 4)
        // First server keypoint of card_a is (187, 98) in canonical px (nf=650 card_a.json).
        let (x0, y0): (Float, Float) = fp.keypointsXY.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self); return (f[0], f[1])
        }
        XCTAssertEqual(x0, 187, accuracy: 1.0)
        XCTAssertEqual(y0, 98, accuracy: 1.0)
    }

    // Guard: a row whose global_vec blob doesn't decode to exactly `dim` float16s would otherwise
    // silently misalign every subsequent row in Matcher's row*dim striding. Built from scratch
    // (no committed binary fixture) so the schema mirrors fpcore.fpdb's card_fp table.
    func testLoadGlobalVectorsThrowsOnMalformedRow() throws {
        let path = NSTemporaryDirectory() + "fp-malformed-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE card_fp(card_id TEXT PRIMARY KEY, fp_version INTEGER, global_vec BLOB,
                                  kp_count INTEGER, keypoints BLOB, descriptors BLOB);
            """)
            try db.execute(sql: "INSERT INTO card_fp(card_id, global_vec) VALUES (?, ?)",
                            arguments: ["bad_card", Data(repeating: 0, count: 10)]) // 5 float16s, not 512
        }
        try q.close()

        let store = try FingerprintStore(path: path)
        defer { try? store.close() }
        XCTAssertThrowsError(try store.loadGlobalVectors()) { error in
            guard case let FingerprintStoreError.malformedGlobalVec(cardId, expected, got) = error else {
                XCTFail("expected malformedGlobalVec, got \(error)"); return
            }
            XCTAssertEqual(cardId, "bad_card")
            XCTAssertEqual(expected, FingerprintConstants.globalVecDim)
            XCTAssertEqual(got, 5)
        }
    }
}
