import Foundation

/// Device-side global BoVW vector, computed identically to fpcore.codebook.global_vec:
/// histogram of assigned words × idf, L2-normalized, stored as float16. The intermediate
/// math is done in Double to mirror NumPy's float64 accumulation before the f16 cast.
enum VisualFingerprint {
    static func globalVector(descriptors: Data, codebook cb: Codebook) -> [Float16] {
        let k = cb.k
        let n = descriptors.count / 32
        var counts = [Double](repeating: 0, count: k)
        if n > 0 {
            let bytes = [UInt8](descriptors)
            var row = [UInt8](repeating: 0, count: 32)
            for i in 0..<n {
                for b in 0..<32 { row[b] = bytes[i * 32 + b] }
                counts[cb.assignWord(descriptor: row)] += 1
            }
        }
        var v = [Double](repeating: 0, count: k)
        var norm = 0.0
        for j in 0..<k { let x = counts[j] * Double(cb.idf[j]); v[j] = x; norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for j in 0..<k { v[j] /= norm } }
        return v.map { Float16($0) }
    }

    /// Generic over `Collection` (not just `[Float16]`, and `a`/`b` need not be the same concrete
    /// type) so `Matcher.narrow` can score a `[Float16]` query against an `ArraySlice` row of the
    /// shared reference matrix — no per-row copy — while every existing `[Float16]` call site
    /// keeps compiling unchanged.
    static func cosine<A: Collection, B: Collection>(_ a: A, _ b: B) -> Double
        where A.Element == Float16, B.Element == Float16 {
        precondition(a.count == b.count)
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) {
            let xd = Double(x), yd = Double(y)
            dot += xd * yd; na += xd * xd; nb += yd * yd
        }
        if na == 0 || nb == 0 { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
