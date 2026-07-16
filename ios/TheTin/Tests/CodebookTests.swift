import XCTest
import CryptoKit
@testable import TheTin

final class CodebookTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    func testBundledCodebookLoadsAndMatchesKnownHash() throws {
        let cb = try Codebook.bundled(in: bundle())
        XCTAssertEqual(cb.k, FingerprintConstants.codebookK)
        XCTAssertEqual(cb.centroids.count, cb.k * 32)
        XCTAssertEqual(cb.idf.count, cb.k)
        XCTAssertEqual(cb.sha256Hex, FingerprintConstants.codebookSHA256)
    }

    func testRejectsBadMagic() {
        var bytes = [UInt8]("XXXX".utf8)
        bytes += [UInt8](repeating: 0, count: 12)
        XCTAssertThrowsError(try Codebook.load(Data(bytes)))
    }

    func testRejectsTruncated() {
        // Valid header claiming K=512 but no body.
        var bytes = [UInt8]("FPCB".utf8)
        bytes += le32(1) + le32(512) + le32(32)
        XCTAssertThrowsError(try Codebook.load(Data(bytes)))
    }

    // A descriptor equal to centroid row j must assign to a word whose centroid
    // is bit-identical to row j (distance 0) — proves argmin picks the exact match.
    func testAssignsExactCentroidRow() throws {
        let cb = try Codebook.bundled(in: bundle())
        for j in [0, 1, 7, 100, 511] {
            let row = Array(cb.centroids[j*32..<j*32+32])
            let w = cb.assignWord(descriptor: row)
            let wRow = Array(cb.centroids[w*32..<w*32+32])
            XCTAssertEqual(wRow, row, "row \(j) assigned to a non-identical centroid \(w)")
        }
    }

    // Two centroids equidistant from the descriptor → lowest index wins (ties → argmin).
    func testTieBreaksToLowestIndex() throws {
        var c0 = [UInt8](repeating: 0, count: 32); c0[0] = 0b0000_0001  // 1 bit set
        var c1 = [UInt8](repeating: 0, count: 32); c1[0] = 0b0000_0010  // different 1 bit
        var body = c0 + c1
        // idf: two float16 ones
        body += f16LE(1) + f16LE(1)
        var bytes = [UInt8]("FPCB".utf8) + le32(1) + le32(2) + le32(32) + body
        let cb = try Codebook.load(Data(bytes))
        let desc = [UInt8](repeating: 0, count: 32)  // dist 1 to each → tie
        XCTAssertEqual(cb.assignWord(descriptor: desc), 0)
    }

    // MARK: helpers
    private func le32(_ v: UInt32) -> [UInt8] { [0,8,16,24].map { UInt8((v >> $0) & 0xff) } }
    private func f16LE(_ v: Float16) -> [UInt8] { let b = v.bitPattern; return [UInt8(b & 0xff), UInt8(b >> 8)] }
}
