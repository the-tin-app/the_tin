import CoreGraphics
import Foundation

/// Where the printed border sits on a card. This is a MEASUREMENT and nothing else: no predicted
/// grade, no grader's scale, no pass/fail. What corners/edges/surface would need — a CNN ensemble
/// and a labelled corpus of graded cards — we deliberately do not have and do not claim (see the
/// 2026-08-14 research).
///
/// ⚠️ **The user's dragged lines are the source of truth, not `CenteringMeter`.** Measured against
/// the 74 real photos in `test_images/` (`fingerprint/eval/centering_check.swift`, 2026-08-14),
/// automatic detection was confidently wrong: 68 of 74 produced a number, none hit the refusal
/// path, and readings ran to 90/10 and 5/95. Rendering the detected edges over the plate showed
/// them landing in artwork and under title bars, because the plate's edges are only approximately
/// the card's edges and "first colour change inward" is not the printed frame on a full-art. So
/// the detector seeds the editor and the user drags from there — which also means the number on
/// screen is one a human has looked at.
/// Eight lines, not four: the card's cut edge AND the printed border's inner edge, on all four
/// sides. Stored as insets from the corresponding plate edge, in plate pixels.
///
/// Four lines assumed the plate's edge WAS the card's edge. It isn't — doc-seg's quad wanders
/// inside the card or takes in background, and a border ratio amplifies opposite-side error, which
/// is most of why automatic detection read 90/10 on real photos. Placing the outer line by hand
/// removes that dependency completely: the detector's crop no longer has to be accurate, only
/// close enough to see.
struct Centering: Equatable, Codable {
    var outerLeft: Int, innerLeft: Int
    var outerRight: Int, innerRight: Int
    var outerTop: Int, innerTop: Int
    var outerBottom: Int, innerBottom: Int

    /// Border widths — the gap between the card's edge and the printed frame on each side. This is
    /// the actual measurement; the eight insets exist so the lines can be put back where they were.
    var left: Int { innerLeft - outerLeft }
    var right: Int { innerRight - outerRight }
    var top: Int { innerTop - outerTop }
    var bottom: Int { innerBottom - outerBottom }

    /// Border widths measured from the plate edge — what `CenteringMeter` produces, and the
    /// starting position the user then corrects by dragging the outer lines onto the card.
    init(left: Int, right: Int, top: Int, bottom: Int) {
        outerLeft = 0; innerLeft = left
        outerRight = 0; innerRight = right
        outerTop = 0; innerTop = top
        outerBottom = 0; innerBottom = bottom
    }

    init(outerLeft: Int, innerLeft: Int, outerRight: Int, innerRight: Int,
         outerTop: Int, innerTop: Int, outerBottom: Int, innerBottom: Int) {
        self.outerLeft = outerLeft; self.innerLeft = innerLeft
        self.outerRight = outerRight; self.innerRight = innerRight
        self.outerTop = outerTop; self.innerTop = innerTop
        self.outerBottom = outerBottom; self.innerBottom = innerBottom
    }

    /// Share of the total left+right border that sits on the left, 0...1. 0.5 is dead centre.
    var horizontal: Double {
        let total = left + right
        return total > 0 ? Double(left) / Double(total) : 0.5
    }

    /// Share of the total top+bottom border that sits on the top, 0...1. 0.5 is dead centre.
    var vertical: Double {
        let total = top + bottom
        return total > 0 ? Double(top) / Double(total) : 0.5
    }

    /// "54/46" — the collector's shorthand. The second number is the complement of the first, so
    /// a rounded pair always totals 100 rather than reading "54/47".
    private static func pair(_ share: Double) -> String {
        let first = Int((share * 100).rounded())
        return "\(first)/\(100 - first)"
    }

    /// "54/46 L-R · 51/49 T-B". Deliberately just the two ratios: naming a grade, or a threshold
    /// a grader uses, would turn a measurement into a prediction we can't stand behind.
    var summary: String { "\(Self.pair(horizontal)) L-R · \(Self.pair(vertical)) T-B" }

    /// The same two ratios as speech — "54/46 L-R" reads as "54 slash 46 L dash R" otherwise.
    var spokenSummary: String {
        let h = Self.pair(horizontal).replacingOccurrences(of: "/", with: " to ")
        let v = Self.pair(vertical).replacingOccurrences(of: "/", with: " to ")
        return "Centering \(h) left to right, \(v) top to bottom"
    }
}

enum CenteringMeter {
    /// Pixels of the outermost edge to ignore. `CIPerspectiveCorrection` resamples, so the first
    /// row/column of the plate is a blend of the card edge and whatever was behind it.
    static let edgeSkip = 3

    /// Per-channel difference from the sampled border colour that counts as "no longer border".
    /// ponytail: fixed threshold; make it adaptive (per-card border contrast) only if silver
    /// and black-bordered cards measure worse than yellow ones on real photos.
    static let channelDelta = 40.0

    /// Consecutive differing pixels required to accept a transition, so one glare speck or dust
    /// mote can't shorten a border.
    static let runLength = 3

    /// Fraction of the plate searched inward from each edge before giving up. Real borders are
    /// well under 10%; 25% leaves room for a badly mis-cut card without wandering into the art.
    static let searchFraction = 0.25

    /// Scanlines sampled per edge. Taken across the middle half of the perpendicular axis so
    /// rounded corners — where two borders meet and the card radius eats the edge — never vote.
    static let scanlines = 9

    /// Measures the four border widths. Returns nil if any edge never transitions: a borderless
    /// full-art, a plate that isn't really a card, or a shot too blown out to read. A refusal is
    /// the correct output there — a number would be invented.
    static func measure(bgra: Data, width: Int, height: Int, bytesPerRow: Int) -> Centering? {
        guard width > 8, height > 8, bgra.count >= bytesPerRow * height else { return nil }

        return bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Centering? in
            let p = raw.bindMemory(to: UInt8.self)
            @inline(__always) func bgr(_ x: Int, _ y: Int) -> (Double, Double, Double) {
                let i = y * bytesPerRow + x * 4
                return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
            }
            @inline(__always) func differs(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
                max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2))) > channelDelta
            }

            /// Walks inward along one scanline. `pixel(depth)` yields the pixel `depth` in from
            /// the edge; the border colour is sampled at `edgeSkip` and the width is the depth of
            /// the first of `runLength` consecutive pixels that stop matching it.
            func borderWidth(limit: Int, pixel: (Int) -> (Double, Double, Double)) -> Int? {
                let reference = pixel(edgeSkip)
                var run = 0
                for depth in (edgeSkip + 1)..<limit {
                    if differs(pixel(depth), reference) {
                        run += 1
                        if run == runLength { return depth - runLength + 1 }
                    } else {
                        run = 0
                    }
                }
                return nil
            }

            /// Median of the per-scanline widths for one edge. Nil unless a majority of the
            /// scanlines actually found a transition — a couple of glare-blown scanlines are
            /// survivable, an edge that mostly doesn't resolve is not.
            func edge(limit: Int, span: Int, pixel: @escaping (Int, Int) -> (Double, Double, Double)) -> Int? {
                var widths: [Int] = []
                for n in 0..<scanlines {
                    // Middle half of the span, evenly spaced.
                    let along = span / 4 + (span / 2) * n / (scanlines - 1)
                    if let w = borderWidth(limit: limit, pixel: { pixel($0, min(along, span - 1)) }) {
                        widths.append(w)
                    }
                }
                guard widths.count > scanlines / 2 else { return nil }
                widths.sort()
                return widths[widths.count / 2]
            }

            let hLimit = Int(Double(width) * searchFraction)
            let vLimit = Int(Double(height) * searchFraction)
            guard let left = edge(limit: hLimit, span: height, pixel: { bgr($0, $1) }),
                  let right = edge(limit: hLimit, span: height, pixel: { bgr(width - 1 - $0, $1) }),
                  let top = edge(limit: vLimit, span: width, pixel: { bgr($1, $0) }),
                  let bottom = edge(limit: vLimit, span: width, pixel: { bgr($1, height - 1 - $0) })
            else { return nil }

            return Centering(left: left, right: right, top: top, bottom: bottom)
        }
    }

    /// Seeds the editor from a stored plate. Redraws into a known BGRA layout first: a JPEG comes
    /// back with whatever component order and row padding ImageIO chose, and the walk below reads
    /// raw bytes.
    static func measure(cgImage: CGImage) -> Centering? {
        let w = cgImage.width, h = cgImage.height, stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return measure(bgra: Data(buf), width: w, height: h, bytesPerRow: stride)
    }

    /// How far off square-on the shot was, as the largest relative disagreement between opposite
    /// edges of the detected quad. 0 is fronto-parallel; ~0.1 is a noticeably tilted phone.
    ///
    /// This is the gate the measurement needs, and it is NOT the accelerometer: gravity tells you
    /// the phone is level, which only implies square-on when the card is lying flat. The quad
    /// tells you about the phone and the card together, which is the thing that actually skews
    /// the border widths — a tilt toward one edge foreshortens the border on that side, and the
    /// perspective correction stretches the error back out into the plate.
    ///
    /// ponytail: relative edge lengths only — cheap and monotonic in tilt, but not a calibrated
    /// angle. Solve for the homography's rotation if a real degree readout is ever wanted.
    static func skew(_ q: CardQuad) -> Double {
        @inline(__always) func len(_ a: CGPoint, _ b: CGPoint) -> Double {
            Double(hypot(b.x - a.x, b.y - a.y))
        }
        @inline(__always) func disagreement(_ a: Double, _ b: Double) -> Double {
            let m = max(a, b)
            return m > 0 ? abs(a - b) / m : 0
        }
        let top = len(q.topLeft, q.topRight), bottom = len(q.bottomLeft, q.bottomRight)
        let left = len(q.topLeft, q.bottomLeft), right = len(q.topRight, q.bottomRight)
        return max(disagreement(top, bottom), disagreement(left, right))
    }
}
