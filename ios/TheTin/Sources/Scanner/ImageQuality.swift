import Foundation

enum ImageQuality {
    @inline(__always) static func specularScore(r: Double, g: Double, b: Double) -> Double {
        let luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let chroma = (mx - mn) / 255.0
        return luma * (1.0 - chroma)
    }

    static func glareCoverage(bgra: Data, width: Int, height: Int, bytesPerRow: Int,
                              lumaThreshold: Double = 0.82, chromaThreshold: Double = 0.10) -> Double {
        var specular = 0
        bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { let row = y * bytesPerRow
                for x in 0..<width { let i = row + x * 4
                    let b = Double(p[i]), g = Double(p[i+1]), r = Double(p[i+2])
                    let luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                    let chroma = (mx - mn) / 255.0
                    if luma >= lumaThreshold && chroma <= chromaThreshold { specular += 1 }
                }
            }
        }
        return Double(specular) / Double(width * height)
    }

    static func focus(bgra: Data, width: Int, height: Int, bytesPerRow: Int) -> Double {
        guard width >= 3, height >= 3 else { return 0 }
        var lum = [Double](repeating: 0, count: width * height)
        bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { let row = y * bytesPerRow
                for x in 0..<width { let i = row + x * 4
                    lum[y * width + x] = 0.299 * Double(p[i+2]) + 0.587 * Double(p[i+1]) + 0.114 * Double(p[i])
                }
            }
        }
        var vals = [Double](); vals.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            let c = lum[y * width + x]
            let l = 4 * c - lum[y*width + x-1] - lum[y*width + x+1] - lum[(y-1)*width + x] - lum[(y+1)*width + x]
            vals.append(l)
        } }
        let mean = vals.reduce(0, +) / Double(vals.count)
        return vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
    }
}
