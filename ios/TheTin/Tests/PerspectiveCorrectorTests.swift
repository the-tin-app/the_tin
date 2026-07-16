import XCTest
import CoreImage
@testable import TheTin

final class PerspectiveCorrectorTests: XCTestCase {
    func testCorrectsToCanonicalDims() throws {
        // A plain image; identity-ish quad spanning the full extent → 660x920 BGRA out.
        let src = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 420))
        let quad = CardQuad(topLeft: CGPoint(x: 0, y: 420), topRight: CGPoint(x: 300, y: 420),
                            bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 300, y: 0))
        let out = try XCTUnwrap(PerspectiveCorrector.canonicalBGRA(from: src, quad: quad, context: CIContext()))
        XCTAssertEqual(out.bytesPerRow, 660 * 4)
        XCTAssertEqual(out.data.count, 660 * 4 * 920)
    }
}
