import XCTest
@testable import TheTin

/// The Plan-2 analogue of Plan 1's descriptor parity gate: prove the DEVICE-computed
/// global vector of a card matches the SERVER-shipped vector (high cosine) and clearly
/// rejects a different card. Functional, not byte-exact (cross-platform f16 drift).
final class GlobalVectorParityTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    private func deviceVec(_ name: String) throws -> [Float16] {
        let url = try XCTUnwrap(bundle().url(forResource: name, withExtension: "pngdata"))
        let fp = try XCTUnwrap(ScanFingerprinter.fingerprint(pngData: try Data(contentsOf: url)))
        return VisualFingerprint.globalVector(descriptors: fp.descriptors, codebook: try Codebook.bundled(in: bundle()))
    }

    private func shippedVecs() throws -> [String: [Float16]] {
        struct Doc: Decodable { let card_a: [Double]; let card_b: [Double] }
        let url = try XCTUnwrap(bundle().url(forResource: "global-vec-fixture", withExtension: "json"))
        let doc = try JSONDecoder().decode(Doc.self, from: try Data(contentsOf: url))
        return ["card_a": doc.card_a.map { Float16($0) }, "card_b": doc.card_b.map { Float16($0) }]
    }

    func testDeviceMatchesShippedSameCard() throws {
        let shipped = try shippedVecs()
        let cos = VisualFingerprint.cosine(try deviceVec("card_a"), try XCTUnwrap(shipped["card_a"]))
        print("PARITY same-card cosine = \(cos)")
        XCTAssertGreaterThanOrEqual(cos, 0.98, "device↔server same-card global cosine too low (\(cos))")
    }

    func testDeviceRejectsDifferentCard() throws {
        let shipped = try shippedVecs()
        let same = VisualFingerprint.cosine(try deviceVec("card_a"), try XCTUnwrap(shipped["card_a"]))
        let diff = VisualFingerprint.cosine(try deviceVec("card_a"), try XCTUnwrap(shipped["card_b"]))
        print("PARITY same=\(same) diff=\(diff)")
        XCTAssertLessThan(diff, same - 0.1, "insufficient discrimination gap: same=\(same) diff=\(diff)")
    }
}
