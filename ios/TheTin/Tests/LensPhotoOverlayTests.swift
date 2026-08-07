import CoreGraphics
import XCTest
@testable import TheTin

/// Pure geometry: where a detected quad lands once the photo is drawn `scaledToFit`.
///
/// Two corrections are under test, and both are invisible until a box sits on the wrong card:
/// `scaledToFit` letterboxes (so the drawn image is NOT the container's size), and Vision's pixel
/// space is bottom-left origin against SwiftUI's top-left (so y flips).
final class LensPhotoOverlayTests: XCTestCase {

    private func quad(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CardQuad {
        CardQuad(topLeft: CGPoint(x: x, y: y + h), topRight: CGPoint(x: x + w, y: y + h),
                 bottomLeft: CGPoint(x: x, y: y), bottomRight: CGPoint(x: x + w, y: y))
    }

    /// Container aspect == image aspect, so there are no bars: only the flip applies.
    func testNoLetterboxJustTheFlip() {
        let r = LensPhotoOverlay.rect(quad: quad(x: 0, y: 0, w: 40, h: 20),
                                      extent: CGRect(x: 0, y: 0, width: 400, height: 200),
                                      in: CGSize(width: 200, height: 100))
        // Bottom-left in Vision space is bottom-left on screen: y runs 90...100 of 100.
        XCTAssertEqual(r, CGRect(x: 0, y: 90, width: 20, height: 10))
    }

    /// The case the naive `geo.size / extent` scaling gets wrong: a 2:1 photo in a square, so the
    /// drawn image is 100×50 centred with 25 pt of bar above and below.
    func testLetterboxedContainerOffsetsEveryBox() {
        let ext = CGRect(x: 0, y: 0, width: 400, height: 200)
        let size = CGSize(width: 100, height: 100)

        let bottomLeft = LensPhotoOverlay.rect(quad: quad(x: 0, y: 0, w: 40, h: 20),
                                               extent: ext, in: size)
        XCTAssertEqual(bottomLeft, CGRect(x: 0, y: 70, width: 10, height: 5))

        let topRight = LensPhotoOverlay.rect(quad: quad(x: 360, y: 180, w: 40, h: 20),
                                             extent: ext, in: size)
        XCTAssertEqual(topRight, CGRect(x: 90, y: 25, width: 10, height: 5))

        // Every box stays inside the drawn image, never in the bars.
        XCTAssertGreaterThanOrEqual(topRight.minY, 25)
        XCTAssertLessThanOrEqual(bottomLeft.maxY, 75)
    }

    /// A `CIImage` extent is not always origin-zero (any crop moves it), and quads come back in
    /// that same space — so the origin has to be subtracted before scaling.
    func testExtentOriginIsSubtracted() {
        let r = LensPhotoOverlay.rect(quad: quad(x: 100, y: 50, w: 40, h: 20),
                                      extent: CGRect(x: 100, y: 50, width: 400, height: 200),
                                      in: CGSize(width: 200, height: 100))
        XCTAssertEqual(r, CGRect(x: 0, y: 90, width: 20, height: 10))
    }

    func testEmptyExtentIsHarmless() {
        XCTAssertEqual(LensPhotoOverlay.rect(quad: quad(x: 0, y: 0, w: 1, h: 1),
                                             extent: .zero, in: CGSize(width: 10, height: 10)),
                       .zero)
    }
}
