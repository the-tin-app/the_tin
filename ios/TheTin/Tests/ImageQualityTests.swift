import XCTest
@testable import TheTin

final class ImageQualityTests: XCTestCase {
    // Build a width×height BGRA buffer from an (r,g,b) generator (0–255).
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

    func testGlareCoverageAllWhiteIsOne() {
        let d = bgra(8, 8) { _, _ in (255, 255, 255) }   // blown-out → specular
        XCTAssertEqual(ImageQuality.glareCoverage(bgra: d, width: 8, height: 8, bytesPerRow: 32), 1.0, accuracy: 0.001)
    }

    func testGlareCoverageSaturatedColorIsZero() {
        let d = bgra(8, 8) { _, _ in (200, 0, 0) }       // bright but high chroma → not specular
        XCTAssertEqual(ImageQuality.glareCoverage(bgra: d, width: 8, height: 8, bytesPerRow: 32), 0.0, accuracy: 0.001)
    }

    func testFocusHigherForEdgeThanFlat() {
        let flat = bgra(8, 8) { _, _ in (128, 128, 128) }
        let edged = bgra(8, 8) { x, _ in x < 4 ? (0, 0, 0) : (255, 255, 255) }
        XCTAssertGreaterThan(ImageQuality.focus(bgra: edged, width: 8, height: 8, bytesPerRow: 32),
                             ImageQuality.focus(bgra: flat, width: 8, height: 8, bytesPerRow: 32))
    }

    /// The production floor (ScanModel minFocus=40) must separate a sharp textured plate from
    /// the same plate under heavy motion blur. Checkerboard = worst-case sharp texture; a 15px
    /// box blur stands in for the hand-jerk frames the live gate should skip.
    func testFocusFloorSeparatesSharpFromMotionBlur() {
        let w = 128, h = 128, stride = w * 4
        var sharp = Data(count: stride * h)
        for y in 0..<h { for x in 0..<w {
            let v: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 230 : 25
            let i = y * stride + x * 4
            sharp[i] = v; sharp[i+1] = v; sharp[i+2] = v; sharp[i+3] = 255
        } }
        // 15px horizontal + vertical box blur of the same image (2D for stronger motion blur)
        var blurred = Data(count: stride * h)
        for y in 0..<h { for x in 0..<w {
            var sum = 0
            for dy in -7...7 { for dx in -7...7 {
                let ny = min(max(y + dy, 0), h - 1)
                let nx = min(max(x + dx, 0), w - 1)
                sum += Int(sharp[ny * stride + nx * 4])
            } }
            let v = UInt8(sum / 225)  // 15x15 = 225 samples
            let i = y * stride + x * 4
            blurred[i] = v; blurred[i+1] = v; blurred[i+2] = v; blurred[i+3] = 255
        } }
        XCTAssertGreaterThan(ImageQuality.focus(bgra: sharp, width: w, height: h, bytesPerRow: stride), 40)
        XCTAssertLessThan(ImageQuality.focus(bgra: blurred, width: w, height: h, bytesPerRow: stride), 40)
    }
}
