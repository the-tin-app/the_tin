import CoreGraphics
import UIKit
import XCTest
@testable import TheTin

/// Synthetic plates only. The measurement is pure geometry over pixels — a card photo would add
/// no assurance the maths is right, only that Vision found the card, which `CardDetectorTests`
/// already covers.
final class CenteringTests: XCTestCase {
    private let width = 660, height = 920

    /// A plate with a solid border and a rectangular "art" window inset by the given widths.
    private func plate(left: Int, right: Int, top: Int, bottom: Int) -> Data {
        let stride = width * 4
        var buf = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                let inArt = x >= left && x < width - right && y >= top && y < height - bottom
                // BGRA. Border is card-yellow; art is a dark blue-grey.
                buf[i] = inArt ? 90 : 0        // B
                buf[i + 1] = inArt ? 60 : 220  // G
                buf[i + 2] = inArt ? 40 : 255  // R
                buf[i + 3] = 255
            }
        }
        return Data(buf)
    }

    private func measure(_ data: Data) -> Centering? {
        CenteringMeter.measure(bgra: data, width: width, height: height, bytesPerRow: width * 4)
    }

    func testMeasuresKnownBorderWidths() throws {
        let c = try XCTUnwrap(measure(plate(left: 40, right: 20, top: 30, bottom: 60)))
        XCTAssertEqual(c.left, 40)
        XCTAssertEqual(c.right, 20)
        XCTAssertEqual(c.top, 30)
        XCTAssertEqual(c.bottom, 60)
        // Twice as much border on the left as the right.
        XCTAssertEqual(c.horizontal, 40.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(c.vertical, 30.0 / 90.0, accuracy: 0.001)
    }

    func testAPerfectlyCentredCardReadsAsHalf() throws {
        let c = try XCTUnwrap(measure(plate(left: 35, right: 35, top: 45, bottom: 45)))
        XCTAssertEqual(c.horizontal, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.vertical, 0.5, accuracy: 0.001)
    }

    /// A borderless full-art has no border to find. Nil is what makes the editor open on a plain
    /// nominal inset — visibly a starting position — instead of a confident wrong seed.
    func testABorderlessPlateRefusesToMeasure() {
        let stride = width * 4
        let flat = Data([UInt8](repeating: 200, count: stride * height))
        XCTAssertNil(CenteringMeter.measure(bgra: flat, width: width, height: height, bytesPerRow: stride))
    }

    /// A border so wide it exceeds the search window is also a refusal, not a clamp.
    func testAnUnfindableTransitionRefusesToMeasure() {
        let deep = Int(Double(width) * CenteringMeter.searchFraction) + 10
        XCTAssertNil(measure(plate(left: deep, right: deep, top: deep, bottom: deep)))
    }

    func testSummaryReadsAsTheCollectorsShorthand() throws {
        let c = try XCTUnwrap(measure(plate(left: 54, right: 46, top: 51, bottom: 49)))
        XCTAssertEqual(c.summary, "54/46 L-R · 51/49 T-B")
        XCTAssertEqual(c.spokenSummary,
                       "Centering 54 to 46 left to right, 51 to 49 top to bottom")
    }

    /// Rounding each side independently would print "51/50" here. The pair has to total 100 or
    /// the readout looks broken.
    func testAPairAlwaysTotalsAHundred() {
        let c = Centering(left: 101, right: 99, top: 50, bottom: 50)
        XCTAssertEqual(c.summary, "51/49 L-R · 50/50 T-B")
    }

    /// The editor seeds from a stored JPEG, not from the live BGRA plate, and a JPEG comes back
    /// with whatever component order and row padding ImageIO chose. Seeding through that path has
    /// to land in the same place as the raw one, or every editor opens with the lines misplaced.
    func testSeedingFromAStoredImageMatchesTheRawMeasurement() throws {
        let data = plate(left: 40, right: 20, top: 30, bottom: 60)
        let raw = try XCTUnwrap(measure(data))
        let frame = CanonicalFrame(pixels: data, width: width, height: height,
                                   bytesPerRow: width * 4, focus: 100, glareCoverage: 0,
                                   quadConfidence: 1, skew: 0, quad: nil, degrees: 0)
        // Round-trip exactly as a draft does: encode to JPEG, decode, seed.
        let jpeg = try XCTUnwrap(frame.jpegData())
        let decoded = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        let seeded = try XCTUnwrap(CenteringMeter.measure(cgImage: decoded))
        // JPEG is lossy, so the edge can land a pixel or two out; what must not happen is the
        // whole reading shifting because the bytes were read in the wrong order.
        XCTAssertLessThanOrEqual(abs(seeded.left - raw.left), 2, "left seed drifted")
        XCTAssertLessThanOrEqual(abs(seeded.right - raw.right), 2, "right seed drifted")
        XCTAssertLessThanOrEqual(abs(seeded.top - raw.top), 2, "top seed drifted")
        XCTAssertLessThanOrEqual(abs(seeded.bottom - raw.bottom), 2, "bottom seed drifted")
    }

    /// The whole reason for eight lines rather than four. With the card's cut edge placed by hand,
    /// the reading no longer depends on where the detector's crop landed — which is the error that
    /// made automatic measurement read 90/10 on real photos, because a ratio amplifies opposite-side
    /// crop error. The same card measured on a tight crop and on a crop 25px wider on one side and
    /// 10px on the other must give the same answer.
    func testTheRatioDoesNotDependOnWhereTheCropLanded() {
        let tight = Centering(outerLeft: 0, innerLeft: 40, outerRight: 0, innerRight: 20,
                              outerTop: 0, innerTop: 30, outerBottom: 0, innerBottom: 60)
        let loose = Centering(outerLeft: 25, innerLeft: 65, outerRight: 10, innerRight: 30,
                              outerTop: 18, innerTop: 48, outerBottom: 4, innerBottom: 64)
        XCTAssertEqual(tight.left, loose.left)
        XCTAssertEqual(tight.right, loose.right)
        XCTAssertEqual(tight.summary, loose.summary)
        XCTAssertEqual(loose.summary, "67/33 L-R · 33/67 T-B")
    }

    /// A four-argument `Centering` is the detector's output, measured from the plate edge — so its
    /// outer lines sit at zero and the widths read straight through.
    func testWidthsOnlyInitPutsTheCardEdgeAtThePlateEdge() {
        let c = Centering(left: 40, right: 20, top: 30, bottom: 60)
        XCTAssertEqual(c.outerLeft, 0)
        XCTAssertEqual(c.innerLeft, 40)
        XCTAssertEqual(c.left, 40)
    }

    /// A card tilted away from the lens images as a trapezoid: its left and right edges converge
    /// on a vanishing point. Adding margin has to extend along those same edge lines, or the
    /// expanded quad describes a different plane than the card does — and correcting with it
    /// leaves residual keystone, so a straight editor line lined up at one end sits off the edge
    /// at the other. Reported on device 2026-08-15; this is the property that was violated.
    func testMarginFollowsTheCardsOwnEdgesUnderPerspective() {
        // Top edge shorter than the bottom — the card is leaning back.
        let tilted = CardQuad(topLeft: CGPoint(x: 20, y: 100), topRight: CGPoint(x: 80, y: 100),
                              bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 100, y: 0))
        let factor: CGFloat = 1.25
        let wide = tilted.expanded(by: factor)

        // The invariant that makes the correction square: seen through the EXPANDED quad's own
        // coordinates, the card is an axis-aligned rectangle inset by the margin — 0.1...0.9 of
        // the picture for a 1.25 crop. Correcting the expanded quad to a rectangle therefore puts
        // the card's edges parallel to the picture's, which is what a straight line needs.
        let lo = ((factor - 1) / 2) / factor, hi = 1 - lo
        for (u, v, expected) in [(lo, lo, tilted.topLeft), (hi, lo, tilted.topRight),
                                 (lo, hi, tilted.bottomLeft), (hi, hi, tilted.bottomRight)] {
            let p = wide.projected(u: u, v: v)
            XCTAssertEqual(p.x, expected.x, accuracy: 0.01, "card corner moved in the wide crop")
            XCTAssertEqual(p.y, expected.y, accuracy: 0.01, "card corner moved in the wide crop")
        }

        // And prove centroid scaling genuinely fails it — otherwise the test passes for the bug
        // too and pins nothing.
        let c = tilted.center
        func push(_ p: CGPoint) -> CGPoint {
            CGPoint(x: c.x + (p.x - c.x) * factor, y: c.y + (p.y - c.y) * factor)
        }
        let naive = CardQuad(topLeft: push(tilted.topLeft), topRight: push(tilted.topRight),
                             bottomLeft: push(tilted.bottomLeft), bottomRight: push(tilted.bottomRight))
        let naiveCorner = naive.projected(u: lo, v: lo)
        XCTAssertGreaterThan(hypot(naiveCorner.x - tilted.topLeft.x,
                                   naiveCorner.y - tilted.topLeft.y), 1,
                             "centroid scaling should misplace the card inside the crop — if it "
                             + "doesn't, this quad has no perspective and the test proves nothing")
    }

    /// With no perspective the two approaches must agree — a square-on card's margin is just a
    /// concentric rectangle, and the projective path must not disturb the common case.
    func testMarginOnASquareOnCardIsAPlainConcentricRectangle() {
        let square = CardQuad(topLeft: CGPoint(x: 100, y: 200), topRight: CGPoint(x: 300, y: 200),
                              bottomLeft: CGPoint(x: 100, y: 0), bottomRight: CGPoint(x: 300, y: 0))
        let wide = square.expanded(by: 1.5)
        // 200 wide, 200 tall, so 1.5× adds 50 on each side.
        XCTAssertEqual(wide.topLeft.x, 50, accuracy: 0.01)
        XCTAssertEqual(wide.topLeft.y, 250, accuracy: 0.01)
        XCTAssertEqual(wide.bottomRight.x, 350, accuracy: 0.01)
        XCTAssertEqual(wide.bottomRight.y, -50, accuracy: 0.01)
    }

    /// The corners of the card's own coordinate space must land back on the quad's corners, or
    /// every margin computed from it is offset.
    func testTheCardPlaneMapsItsCornersBackToTheQuad() {
        let tilted = CardQuad(topLeft: CGPoint(x: 20, y: 100), topRight: CGPoint(x: 80, y: 100),
                              bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 100, y: 0))
        for (u, v, expected) in [(0.0, 0.0, tilted.topLeft), (1.0, 0.0, tilted.topRight),
                                 (0.0, 1.0, tilted.bottomLeft), (1.0, 1.0, tilted.bottomRight)] {
            let p = tilted.projected(u: CGFloat(u), v: CGFloat(v))
            XCTAssertEqual(p.x, expected.x, accuracy: 0.01)
            XCTAssertEqual(p.y, expected.y, accuracy: 0.01)
        }
    }

    /// A still photo must come back the way it went in. The scanner resolves 0 vs 180 by
    /// comparing OCR confidence between the two, which on one still guessed wrong and saved the
    /// card upside down (device, 2026-08-15) — and a flip is not cosmetic here: it swaps left
    /// with right, so 55/45 becomes 45/55.
    func testAPhotoIsNeverFlippedEndForEnd() {
        // Portrait card, a bright marker across its top third.
        let w = 400, h = 600, stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * stride + x * 4
                let onCard = (60..<340).contains(x) && (80..<520).contains(y)
                let marker = onCard && y < 160          // near the TOP of the card
                buf[i] = onCard ? (marker ? 255 : 40) : 210         // B
                buf[i + 1] = onCard ? (marker ? 255 : 40) : 210     // G
                buf[i + 2] = onCard ? (marker ? 255 : 40) : 210     // R
                buf[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(buf) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: stride, space: cs,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)!

        guard let jpeg = EditorPlate.fromPhoto(UIImage(cgImage: cg), context: CIContext()),
              let out = UIImage(data: jpeg)?.cgImage else {
            // Detection is Vision's call and can legitimately find nothing in a synthetic plate;
            // the decision function below is the part this test exists to pin.
            XCTAssertEqual(EditorPlate.uprightDegrees(CGRect(x: 0, y: 0, width: 400, height: 600)), 0)
            return
        }
        XCTAssertGreaterThan(out.height, out.width, "the picture must come out portrait")
        XCTAssertTrue(brighterHalf(of: out) == .top,
                      "the marker started at the top of the card and must still be there")
    }

    /// Portrait stays as-is; only a landscape correction is rotated. Nothing here may return 180.
    func testUprightNeverAsksForAFlip() {
        XCTAssertEqual(EditorPlate.uprightDegrees(CGRect(x: 0, y: 0, width: 400, height: 600)), 0)
        XCTAssertEqual(EditorPlate.uprightDegrees(CGRect(x: 0, y: 0, width: 600, height: 400)), 90)
        for size in [(400, 600), (600, 400), (500, 500)] {
            let d = EditorPlate.uprightDegrees(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            XCTAssertNotEqual(d, 180, "a photo must never be turned end for end")
            XCTAssertNotEqual(d, 270, "nor rotated past vertical")
        }
    }

    /// The scan plate's counterpart to the rule above. The scanner's rotation carries an
    /// OCR-confidence guess at 0-vs-180 that reaches a lock even when it's wrong — matching is
    /// rotation-invariant — and the plate is rendered once and stored, so there is no later frame
    /// to correct it. Geometry survives; the guess does not.
    func testTheScanPlateKeepsTheRotationButNotTheFlip() {
        XCTAssertEqual(EditorPlate.unflipped(0), 0)
        XCTAssertEqual(EditorPlate.unflipped(90), 90, "a sideways card must still be stood up")
        XCTAssertEqual(EditorPlate.unflipped(180), 0, "the flip is the guess — drop it")
        XCTAssertEqual(EditorPlate.unflipped(270), 90)
        for d in [0, 90, 180, 270] {
            XCTAssertNotEqual(EditorPlate.unflipped(d), 180,
                              "a stored plate must never be turned end for end")
            XCTAssertNotEqual(EditorPlate.unflipped(d), 270)
        }
    }

    /// The card-edge knob is pushed outward, and the picture is clipped — so on a line near the
    /// plate's boundary the push has to give way, or the target lands off the picture and stops
    /// being touchable. Zoom masked this completely: the margin grows with zoom, the knob doesn't.
    func testTheCardEdgeKnobStaysOnThePicture() {
        let extent: CGFloat = 360          // picture width in points at 1×
        let radius = CenteringEditorView.knobRadius(zoom: 1)

        // A card edge dragged right out to the plate boundary — the worst case, and the one that
        // produced "I can't grab it" on device.
        let atEdge = CenteringEditorView.knobDistance(lineDistance: 0, isOuter: true,
                                                      extent: extent, zoom: 1)
        XCTAssertGreaterThanOrEqual(atEdge, radius, "the whole target must be on the picture")

        // The far side, for the border knob pushed inward.
        let atFarEdge = CenteringEditorView.knobDistance(lineDistance: extent, isOuter: false,
                                                         extent: extent, zoom: 1)
        XCTAssertLessThanOrEqual(atFarEdge, extent - radius)

        // Away from the boundary the 26pt push is untouched — the clamp must not cost separation
        // in the ordinary case, or a pair of knobs starts stacking on a thin border.
        let outer = CenteringEditorView.knobDistance(lineDistance: 120, isOuter: true,
                                                     extent: extent, zoom: 1)
        let inner = CenteringEditorView.knobDistance(lineDistance: 120, isOuter: false,
                                                     extent: extent, zoom: 1)
        XCTAssertEqual(outer, 120 - 26, accuracy: 0.001)
        XCTAssertEqual(inner, 120 + 26, accuracy: 0.001)
        XCTAssertEqual(inner - outer, 52, accuracy: 0.001)

        // And it holds at every zoom, since the knob is a constant size on screen while the
        // picture's coordinates shrink under it.
        for zoom in [CGFloat(1), 2, 4, 6] {
            let r = CenteringEditorView.knobRadius(zoom: zoom)
            let d = CenteringEditorView.knobDistance(lineDistance: 0, isOuter: true,
                                                     extent: extent, zoom: zoom)
            XCTAssertGreaterThanOrEqual(d, r, "off the picture at \(zoom)×")
            XCTAssertLessThanOrEqual(d, extent - r)
        }
    }

    /// A drag measures its translation from the line's value when the gesture began. That origin
    /// is cleared in `onEnded`, which is not guaranteed to arrive — so an origin left over from a
    /// different line must be discarded, not used. Using it teleported the newly grabbed line
    /// straight to the previous line's position.
    func testAStaleDragOriginIsNotUsedForADifferentLine() {
        typealias Editor = CenteringEditorView
        let stale = (line: Editor.Line.outerLeft, value: CGFloat(100))

        XCTAssertEqual(Editor.dragBase(origin: stale, line: .outerLeft, current: 999), 100,
                       "the line's own origin must survive for the life of its gesture")
        XCTAssertEqual(Editor.dragBase(origin: stale, line: .innerRight, current: 400), 400,
                       "a different line must start from where it actually is, not from 100")
        XCTAssertEqual(Editor.dragBase(origin: nil, line: .outerTop, current: 42), 42,
                       "no origin means this gesture is starting now")
    }

    /// The activation slop, as arithmetic. `DragGesture()` defaults to `minimumDistance: 10`, so
    /// `translation` is already 10pt when `onChanged` first fires — and the editor applies the
    /// whole translation to the position captured at that instant, so the line teleports by
    /// `10 / scale` on activation. At 1× that is ~28 plate pixels against a border one or two
    /// points wide on screen, which is why placing a line at 1× was not possible; at 6× it is
    /// about one border width, which is why zooming looked like a fix.
    ///
    /// This pins the reasoning, not the API: `minimumDistance: 0` is what makes the number zero,
    /// and there is no way to read that back off a `DragGesture`.
    func testTheActivationSlopIsWhatMadeOneXUnusable() {
        // A ~1000×1400 plate shown ~360pt wide — the real geometry on a phone.
        let base = 360.0 / 1000.0
        func teleport(slopPoints: Double, zoom: Double) -> Double { slopPoints / (base * zoom) }

        XCTAssertEqual(teleport(slopPoints: 10, zoom: 1), 27.8, accuracy: 0.5,
                       "the default 10pt slop is ~28 plate pixels at 1×")
        XCTAssertLessThan(teleport(slopPoints: 10, zoom: 6), 5,
                          "and under 5 at 6×, which is why zooming masked it")
        // What the editor actually ships.
        XCTAssertEqual(teleport(slopPoints: 0, zoom: 1), 0,
                       "with minimumDistance 0 there is no slop to apply, at any zoom")
    }

    private enum Half { case top, bottom }

    /// Which half of the image carries more light — enough to tell "flipped" from "not".
    private func brighterHalf(of cg: CGImage) -> Half {
        // `rowBytes`, not `stride` — a local named `stride` shadows the `stride(from:to:by:)`
        // used to sample columns below.
        let w = cg.width, h = cg.height, rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var top = 0.0, bottom = 0.0
        for y in 0..<h {
            for x in stride(from: 0, to: w, by: 4) {
                let i = y * rowBytes + x * 4
                let lum = Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2])
                if y < h / 2 { top += lum } else { bottom += lum }
            }
        }
        return top >= bottom ? .top : .bottom
    }

    /// Opening the entry form assigns the saved photos into it — a nil to filename change. That
    /// must not be mistaken for "the user just took a photo", or the form throws the editor open
    /// on the previously saved picture about a second after you enter it, which is what happened
    /// on device (2026-08-15).
    func testOpeningTheFormDoesNotReopenTheEditor() {
        // populate(): entry's saved picture arrives, nobody asked for a camera.
        XCTAssertFalse(EntryCenteringSection.shouldOpenEditor(
            awaitingCapture: false, old: nil, new: "saved-last-week.jpg"))
        // Re-populating with the same value is not a capture either.
        XCTAssertFalse(EntryCenteringSection.shouldOpenEditor(
            awaitingCapture: false, old: "a.jpg", new: "a.jpg"))
        // A picture the user actually asked for does open it — the flow this exists for.
        XCTAssertTrue(EntryCenteringSection.shouldOpenEditor(
            awaitingCapture: true, old: nil, new: "just-taken.jpg"))
        // Replacing an existing picture opens it too.
        XCTAssertTrue(EntryCenteringSection.shouldOpenEditor(
            awaitingCapture: true, old: "old.jpg", new: "new.jpg"))
        // A capture that produced nothing (cancelled picker) opens nothing.
        XCTAssertFalse(EntryCenteringSection.shouldOpenEditor(
            awaitingCapture: true, old: "old.jpg", new: nil))
    }

    func testSkewIsZeroForASquareOnQuadAndRisesWithTilt() {
        let square = CardQuad(topLeft: CGPoint(x: 0, y: 100), topRight: CGPoint(x: 70, y: 100),
                              bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 70, y: 0))
        XCTAssertEqual(CenteringMeter.skew(square), 0, accuracy: 0.0001)

        // Phone tilted so the top edge is further away: it images shorter than the bottom.
        let tilted = CardQuad(topLeft: CGPoint(x: 7, y: 100), topRight: CGPoint(x: 63, y: 100),
                              bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 70, y: 0))
        XCTAssertEqual(CenteringMeter.skew(tilted), 0.2, accuracy: 0.0001)
    }
}
