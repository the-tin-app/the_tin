import XCTest
import CoreGraphics
@testable import TheTin

final class ScanGuideTests: XCTestCase {
    func testPortraitLiveFrameCrop() {
        let r = ScanGuide.cropRect(in: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        // Width-limited: 92% of width → aspect height, then +10% margin, clamped to the frame.
        XCTAssertEqual(r.width, 1080, accuracy: 1)          // 993.6 * 1.1 clamps to full width
        XCTAssertEqual(r.height, 1524.6, accuracy: 1)       // (993.6 / 0.717) * 1.1
        XCTAssertEqual(r.midX, 540, accuracy: 0.5)
        XCTAssertEqual(r.midY, 960, accuracy: 0.5)
    }

    func testLandscapeStillCrop() {
        let r = ScanGuide.cropRect(in: CGRect(x: 0, y: 0, width: 1920, height: 1440))
        // Height-limited: 92% of height, aspect width.
        XCTAssertEqual(r.height, 1440, accuracy: 1)         // 1324.8 * 1.1 clamps to full height
        XCTAssertEqual(r.width, 1044.7, accuracy: 1)        // 1324.8 * 0.717 * 1.1
        XCTAssertEqual(r.midX, 960, accuracy: 0.5)
    }

    /// Quad sizes below are the REAL Vision observations from the 2026-07-15 on-device binder
    /// failure (7/9 cards stuck on "Frame the card inside the box"): the sideways card quad
    /// must pass (orientation-neutral fit — a card lying sideways in a binder pocket is as
    /// valid as an upright one), and the small card-aspect glare fragment that used to beat
    /// it must be rejected by the minimum-size guard.
    func testQuadPassesIsOrientationNeutralAndSizeGuarded() {
        let guide = ScanGuide.cropRect(in: CGRect(x: 0, y: 0, width: 1920, height: 1440))
        let center = CGPoint(x: guide.midX, y: guide.midY)
        // Sideways card (long axis ⊥ guide's) — IMG_1625's doc-seg quad.
        XCTAssertTrue(ScanGuide.quadPasses(size: CGSize(width: 1387, height: 1006), center: center, in: guide))
        // Upright card fitting the window.
        XCTAssertTrue(ScanGuide.quadPasses(size: CGSize(width: 950, height: 1325), center: center, in: guide))
        // Card-aspect glare fragment (IMG_1629) — too small to be the aimed card.
        XCTAssertFalse(ScanGuide.quadPasses(size: CGSize(width: 435, height: 309), center: center, in: guide))
        // Whole binder page — blows the fit cap.
        XCTAssertFalse(ScanGuide.quadPasses(size: CGSize(width: 1946, height: 2662), center: center, in: guide))
        // Right size, but centered outside the window.
        XCTAssertFalse(ScanGuide.quadPasses(size: CGSize(width: 950, height: 1325),
                                            center: CGPoint(x: 100, y: 100), in: guide))
    }
}
