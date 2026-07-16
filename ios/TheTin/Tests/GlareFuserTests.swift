import XCTest
@testable import TheTin

final class GlareFuserTests: XCTestCase {
    private func bgra(_ w: Int, _ h: Int, _ px: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        var d = Data(count: w * h * 4)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let (r, g, b) = px(x, y); let i = (y * w + x) * 4
                p[i] = b; p[i+1] = g; p[i+2] = r; p[i+3] = 255
            } }
        }
        return d
    }

    func testGlareWalkedOffAcrossTwoFrames() {
        let fuser = GlareFuser(width: 2, height: 2)
        // Frame 1: glare (white) at (0,0); true color (blue) elsewhere.
        let f1 = bgra(2, 2) { x, y in (x, y) == (0, 0) ? (255, 255, 255) : (0, 0, 200) }
        // Frame 2: glare at (1,1); true color (blue) elsewhere, incl. (0,0).
        let f2 = bgra(2, 2) { x, y in (x, y) == (1, 1) ? (255, 255, 255) : (0, 0, 200) }
        fuser.ingest(bgra: f1, bytesPerRow: 8)
        let cov = fuser.ingest(bgra: f2, bytesPerRow: 8)

        let plate = fuser.cleanPlate
        // (0,0) must be the true blue from frame 2, not frame 1's white.
        let i = 0
        XCTAssertEqual(plate[i], 200)   // B
        XCTAssertEqual(plate[i+2], 0)   // R
        XCTAssertEqual(cov, 1.0, accuracy: 0.001, "every pixel seen clean in ≥1 frame")
    }
}
