import CoreGraphics
import Foundation
import UIKit

struct CanonicalFrame {
    let pixels: Data          // BGRA, bytesPerRow * height
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let focus: Double
    let glareCoverage: Double
    let quadConfidence: Double
    /// How far off square-on the shot was, from the detected quad — `CenteringMeter.skew`.
    /// 0 when no quad was localised (passthrough), same as `quadConfidence`.
    let skew: Double
    /// The quad this plate was corrected from, and the rotation applied after. Kept so a lock can
    /// re-crop the same card with margin for the centring editor (`EditorPlate`) instead of
    /// detecting it a second time — doc-seg is documented here as non-deterministic, so a second
    /// detection genuinely returns a different quad.
    let quad: CardQuad?
    let degrees: Int
}

struct CardQuad {
    let topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint

    var center: CGPoint {
        CGPoint(x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
                y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4)
    }

    /// Maps a point in the card's own flat coordinates — (0,0) top-left, (1,1) bottom-right — to
    /// where it lands in the image. Heckbert's closed-form square-to-quad projective map, so no
    /// linear solver is needed.
    ///
    /// Values outside 0...1 extrapolate correctly *in the card's plane*, which is the whole point:
    /// it is what lets a margin be added along the card's own edges rather than along the image's.
    func projected(u: CGFloat, v: CGFloat) -> CGPoint {
        let x0 = topLeft.x, y0 = topLeft.y
        let x1 = topRight.x, y1 = topRight.y
        let x2 = bottomRight.x, y2 = bottomRight.y
        let x3 = bottomLeft.x, y3 = bottomLeft.y

        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        var a = x1 - x0, b = x3 - x0, g: CGFloat = 0, h: CGFloat = 0
        var d = y1 - y0, e = y3 - y0
        // sx = sy = 0 means the quad is a parallelogram: no perspective, the map is affine and the
        // projective terms would divide by zero.
        if abs(sx) > .ulpOfOne || abs(sy) > .ulpOfOne {
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > .ulpOfOne else { return topLeft }   // degenerate quad
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
            a = x1 - x0 + g * x1
            b = x3 - x0 + h * x3
            d = y1 - y0 + g * y1
            e = y3 - y0 + h * y3
        }
        let w = g * u + h * v + 1
        guard abs(w) > .ulpOfOne else { return topLeft }
        return CGPoint(x: (a * u + b * v + x0) / w, y: (d * u + e * v + y0) / w)
    }

    /// The same card with margin added on every side, for the centring editor's picture: the outer
    /// lines mark the card's cut edge, and an edge sitting exactly on the boundary of the image is
    /// one you can neither see nor drag a line onto.
    ///
    /// ⚠️ Expanded in the CARD's plane, not by scaling the quad about its centroid in image space.
    /// Those agree only when the quad is already a rectangle. A tilted card images as a trapezoid
    /// whose opposite edges converge on a vanishing point; a centroid-scaled copy converges
    /// somewhere else, so correcting it applies a homography that isn't the card's and leaves
    /// residual keystone — the card's edges come out slightly non-parallel to the picture's, and a
    /// straight line lined up at one end is visibly off at the other. That is exactly what was
    /// reported (2026-08-15). Extrapolating along the card's own axes keeps the vanishing point,
    /// so the correction is the card's own and its edges land square.
    func expanded(by factor: CGFloat) -> CardQuad {
        let m = (factor - 1) / 2
        return CardQuad(topLeft: projected(u: -m, v: -m),
                        topRight: projected(u: 1 + m, v: -m),
                        bottomLeft: projected(u: -m, v: 1 + m),
                        bottomRight: projected(u: 1 + m, v: 1 + m))
    }
}

extension CanonicalFrame {
    /// The plate as an image. `bytesPerRow` is carried through rather than assumed: a
    /// `CVPixelBuffer` row is padded to an alignment boundary (660px wide arrives as 2,688 bytes,
    /// not 2,640), and treating that padding as pixels shears the picture.
    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// JPEG for storage beside the draft. 0.8 keeps a 660×920 plate around 100 KB — the picture
    /// only has to be good enough to place four lines on by eye.
    func jpegData(quality: CGFloat = 0.8) -> Data? {
        cgImage().flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: quality) }
    }
}
