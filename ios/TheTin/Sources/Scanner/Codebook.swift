import Foundation
import CryptoKit

/// Parses the committed FPCB `codebook.bin` and assigns ORB descriptors to visual
/// words with bit-exact 256-bit Hamming distance (argmin, ties → lowest index) —
/// the same integer math as fpcore.codebook, so word ids are identical to the server.
///
/// FPCB byte layout (little-endian):
///   0  magic "FPCB" (4) · 4 format_version u32 (=1) · 8 K u32 · 12 desc_bytes u32 (=32)
///   16 centroids K×32 uint8 (row-major) · 16+K*32 idf K×float16
struct Codebook {
    let k: Int
    let centroids: [UInt8]   // k * 32, row-major
    let idf: [Float]         // k (float16 upcast to Float, exact)
    let sha256Hex: String

    enum CodebookError: Error { case notFound, badMagic, unsupported, truncated }

    static func load(_ data: Data) throws -> Codebook {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, Array(bytes[0..<4]) == Array("FPCB".utf8) else { throw CodebookError.badMagic }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24 }
        let fmt = u32(4), k = u32(8), descBytes = u32(12)
        guard fmt == 1, descBytes == 32 else { throw CodebookError.unsupported }
        let expected = 16 + k * 32 + k * 2
        guard bytes.count == expected else { throw CodebookError.truncated }

        let centroids = Array(bytes[16..<16 + k * 32])
        var idf = [Float](); idf.reserveCapacity(k)
        var off = 16 + k * 32
        for _ in 0..<k {
            let bits = UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
            idf.append(Float(Float16(bitPattern: bits)))
            off += 2
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Codebook(k: k, centroids: centroids, idf: idf, sha256Hex: hash)
    }

    static func bundled(in bundle: Bundle = .main) throws -> Codebook {
        guard let url = bundle.url(forResource: "codebook", withExtension: "bin") else { throw CodebookError.notFound }
        return try load(try Data(contentsOf: url))
    }

    /// argmin_k popcount(desc XOR centroid[k]); ties → lowest index (only replace on strict <).
    func assignWord(descriptor desc: [UInt8]) -> Int {
        precondition(desc.count == 32)
        var bestDist = Int.max
        var bestIdx = 0
        var ci = 0
        for word in 0..<k {
            var dist = 0
            for b in 0..<32 { dist += (desc[b] ^ centroids[ci + b]).nonzeroBitCount }
            ci += 32
            if dist < bestDist { bestDist = dist; bestIdx = word }
        }
        return bestIdx
    }
}
