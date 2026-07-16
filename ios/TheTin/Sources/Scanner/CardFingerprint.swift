import Foundation

struct CardFingerprint {
    let keypoints: [SIMD2<Float>]   // (x, y) in canonical 660x920 space
    let descriptors: Data           // count * 32 bytes, ORB
    var count: Int { keypoints.count }
}

enum ScanFingerprinter {
    static func fingerprint(pngData: Data) -> CardFingerprint? {
        guard let dict = OpenCVBridge.fingerprint(forImageBytes: pngData),
              let n = dict["n"] as? Int,
              let desc = dict["descriptors"] as? Data,
              let kpData = dict["keypoints"] as? Data else { return nil }
        var pts: [SIMD2<Float>] = []
        pts.reserveCapacity(n)
        kpData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<n { pts.append(SIMD2(f[i*5+0], f[i*5+1])) }
        }
        return CardFingerprint(keypoints: pts, descriptors: desc)
    }

    static func fingerprint(pixels: Data, width: Int, height: Int, bytesPerRow: Int) -> CardFingerprint? {
        guard let dict = OpenCVBridge.fingerprint(forPixels: pixels, width: Int32(width),
                                                  height: Int32(height), bytesPerRow: Int32(bytesPerRow)),
              let n = dict["n"] as? Int,
              let desc = dict["descriptors"] as? Data,
              let kpData = dict["keypoints"] as? Data else { return nil }
        var pts: [SIMD2<Float>] = []; pts.reserveCapacity(n)
        kpData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<n { pts.append(SIMD2(f[i*5+0], f[i*5+1])) }
        }
        return CardFingerprint(keypoints: pts, descriptors: desc)
    }
}
