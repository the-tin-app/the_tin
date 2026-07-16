import Foundation

final class GlareFuser {
    private let width: Int, height: Int, cleanScoreThreshold: Double
    private var bestScore: [Double]     // per pixel, lowest specular score seen
    private var plate: [UInt8]          // per pixel BGRA of the best sample
    private var seenClean: [Bool]

    init(width: Int, height: Int, cleanScoreThreshold: Double = 0.72) {
        self.width = width; self.height = height; self.cleanScoreThreshold = cleanScoreThreshold
        bestScore = [Double](repeating: .greatestFiniteMagnitude, count: width * height)
        plate = [UInt8](repeating: 0, count: width * height * 4)
        seenClean = [Bool](repeating: false, count: width * height)
    }

    func reset() {
        for i in bestScore.indices { bestScore[i] = .greatestFiniteMagnitude }
        for i in plate.indices { plate[i] = 0 }
        for i in seenClean.indices { seenClean[i] = false }
    }

    @discardableResult
    func ingest(bgra: Data, bytesPerRow: Int) -> Double {
        bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { let row = y * bytesPerRow
                for x in 0..<width {
                    let si = row + x * 4, idx = y * width + x
                    let b = p[si], g = p[si+1], r = p[si+2]
                    let score = ImageQuality.specularScore(r: Double(r), g: Double(g), b: Double(b))
                    if score <= cleanScoreThreshold { seenClean[idx] = true }
                    if score < bestScore[idx] {
                        bestScore[idx] = score
                        let di = idx * 4
                        plate[di] = b; plate[di+1] = g; plate[di+2] = r; plate[di+3] = 255
                    }
                }
            }
        }
        return coverage
    }

    var cleanPlate: Data { Data(plate) }
    var coverage: Double { Double(seenClean.lazy.filter { $0 }.count) / Double(width * height) }
}
