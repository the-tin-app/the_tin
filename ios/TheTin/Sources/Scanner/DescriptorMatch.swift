import Foundation

/// A server-built fingerprint decoded from the Python `.ref.json` (Task 3 format).
struct ReferenceFingerprint {
    let keypointsXY: Data   // n * 2 float32 (x, y)
    let descriptors: Data   // n * 32 bytes
    let count: Int

    init(jsonData: Data) throws {
        struct Doc: Decodable { let n: Int; let keypoints: [[Float]]; let descriptors_b64: String }
        let doc = try JSONDecoder().decode(Doc.self, from: jsonData)
        self.count = doc.n
        self.descriptors = Data(base64Encoded: doc.descriptors_b64) ?? Data()
        var xy = Data(capacity: doc.n * 2 * 4)
        for k in doc.keypoints { // [x, y, size, angle, response]
            var x = k[0], y = k[1]
            withUnsafeBytes(of: &x) { xy.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { xy.append(contentsOf: $0) }
        }
        self.keypointsXY = xy
    }

    /// Build directly from unpacked pack rows (pixel-space keypoints), for FingerprintStore.
    init(keypointsXY: Data, descriptors: Data, count: Int) {
        self.keypointsXY = keypointsXY
        self.descriptors = descriptors
        self.count = count
    }
}

enum DescriptorMatch {
    static func ransacInliers(_ a: CardFingerprint, _ b: ReferenceFingerprint) -> Int {
        var xyA = Data(capacity: a.count * 2 * 4)
        for p in a.keypoints { var x = p.x, y = p.y
            withUnsafeBytes(of: &x) { xyA.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { xyA.append(contentsOf: $0) } }
        return Int(OpenCVBridge.ransacInliers(between: a.descriptors, keypointsA: xyA, countA: Int32(a.count),
                                              andDescriptors: b.descriptors, keypointsB: b.keypointsXY, countB: Int32(b.count)))
    }
}
