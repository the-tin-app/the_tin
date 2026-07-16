import Foundation
import GRDB

struct FingerprintMeta {
    let fpVersion: Int
    let codebookHash: String
    let canonicalW: Int
    let canonicalH: Int
    let builtAt: String
}

/// One card's geometry, ready for DescriptorMatch (keypoints in canonical pixels).
struct StoredCardFP {
    let cardId: String
    let keypointsXY: Data   // n * 2 float32 (x, y) canonical px
    let descriptors: Data   // n * 32 uint8
    let count: Int
}

/// All per-card global vectors as one contiguous matrix for brute-force NN.
struct GlobalVectors {
    let ids: [String]
    let dim: Int
    let matrix: [Float16]   // ids.count * dim, row-major
}

/// A shipped-pack row that doesn't decode to the expected shape. Thrown, never crashed on, since
/// a malformed pack is a data-integrity problem the caller (FingerprintUpdater's probe, or the
/// matcher's load path) should be able to catch and reject rather than take down the app.
enum FingerprintStoreError: Error, Equatable {
    case malformedGlobalVec(cardId: String, expected: Int, got: Int)
}

/// Read layer over the shipped fingerprints.sqlite (Plan 2 pack). Inverse of fpcore.packing.
final class FingerprintStore {
    let dbQueue: DatabaseQueue

    init(path: String) throws { dbQueue = try DatabaseQueue(path: path) }
    func close() throws { try dbQueue.close() }

    func meta() throws -> FingerprintMeta? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM meta LIMIT 1") else { return nil }
            return FingerprintMeta(fpVersion: r["fp_version"], codebookHash: r["codebook_hash"],
                                   canonicalW: r["canonical_w"], canonicalH: r["canonical_h"], builtAt: r["built_at"])
        }
    }

    func cardCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card_fp") ?? 0 }
    }

    /// All card ids in the pack, in no particular order. Used as the Matcher's candidate pool
    /// fallback — unlike `loadGlobalVectors`, this does not touch `global_vec`.
    func allCardIds() throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT card_id FROM card_fp") }
    }

    func loadGlobalVectors() throws -> GlobalVectors {
        let dim = FingerprintConstants.globalVecDim
        return try dbQueue.read { db in
            var ids: [String] = []
            var matrix: [Float16] = []
            let rows = try Row.fetchCursor(db, sql: "SELECT card_id, global_vec FROM card_fp ORDER BY card_id")
            while let r = try rows.next() {
                let cardId: String = r["card_id"]
                let vec = Self.decodeF16LE(r["global_vec"])
                // Matcher strides this matrix as row*dim; a short/long row silently misaligns
                // every subsequent row's reads, so a shipped-pack defect must throw, not corrupt.
                guard vec.count == dim else {
                    throw FingerprintStoreError.malformedGlobalVec(cardId: cardId, expected: dim, got: vec.count)
                }
                ids.append(cardId)
                matrix.append(contentsOf: vec)
            }
            return GlobalVectors(ids: ids, dim: dim, matrix: matrix)
        }
    }

    func globalVec(id: String) throws -> [Float16]? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT global_vec FROM card_fp WHERE card_id = ?", arguments: [id])
            else { return nil }
            return Self.decodeF16LE(r["global_vec"])
        }
    }

    func cardFP(id: String) throws -> StoredCardFP? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT kp_count, keypoints, descriptors FROM card_fp WHERE card_id = ?", arguments: [id])
            else { return nil }
            let n: Int = r["kp_count"]
            return StoredCardFP(cardId: id,
                                keypointsXY: Self.keypointsToPixels(r["keypoints"], count: n),
                                descriptors: r["descriptors"], count: n)
        }
    }

    // MARK: blob decode (inverse of fpcore.packing)

    private static func decodeF16LE(_ data: Data) -> [Float16] {
        let n = data.count / 2
        var out = [Float16](); out.reserveCapacity(n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                out.append(Float16(bitPattern: UInt16(raw[i * 2]) | (UInt16(raw[i * 2 + 1]) << 8)))
            }
        }
        return out
    }

    /// keypoints blob = n×2 float16 normalized [0,1); multiply back by CANON → float32 px.
    private static func keypointsToPixels(_ data: Data, count n: Int) -> Data {
        let w = Float(FingerprintConstants.canonW), h = Float(FingerprintConstants.canonH)
        var out = Data(capacity: n * 2 * 4)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func f16(_ o: Int) -> Float { Float(Float16(bitPattern: UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8))) }
            for i in 0..<n {
                var x = f16(i * 4 + 0) * w
                var y = f16(i * 4 + 2) * h
                withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}
