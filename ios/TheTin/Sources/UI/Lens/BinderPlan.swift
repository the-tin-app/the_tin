import CoreGraphics
import Foundation

/// How many pockets the binder page has. The user tells us this before the camera opens, and it is
/// what turns slot assignment from a vision problem into arithmetic: there are exactly
/// `rows × cols` pockets, so anything that doesn't land on one is a phantom.
struct BinderShape: Equatable, Codable {
    var rows: Int
    var cols: Int

    /// 2×2 through 5×5 (§5.1). A 1-wide binder has no 2×2 tile to frame, and past 5 the cards are
    /// too small to read a collector number off — which is the measured predictor of whether a card
    /// can be identified at all.
    static let range = 2...5
    static let `default` = BinderShape(rows: 3, cols: 3)

    init(rows: Int, cols: Int) {
        self.rows = min(max(rows, Self.range.lowerBound), Self.range.upperBound)
        self.cols = min(max(cols, Self.range.lowerBound), Self.range.upperBound)
    }

    var pocketsPerPage: Int { rows * cols }
}

/// One pocket, 0-indexed from the top-left of its page.
struct BinderSlot: Hashable, Codable, Comparable, Identifiable {
    let page: Int
    let row: Int
    let col: Int

    var id: String { "\(page).\(row).\(col)" }

    /// Page order, then reading order within the page — the order a human flips and scans in.
    static func < (a: BinderSlot, b: BinderSlot) -> Bool {
        (a.page, a.row, a.col) < (b.page, b.row, b.col)
    }
}

/// One guided photograph: the 2×2 window of pockets it frames.
struct BinderTile: Identifiable, Equatable, Codable {
    let page: Int
    /// Top-left pocket of the 2×2 window, in page coordinates.
    let rowOffset: Int
    let colOffset: Int

    var id: String { "\(page).\(rowOffset).\(colOffset)" }
}

extension CardQuad {
    /// Bounding box in coordinates normalized to `extent`, **top-left origin**.
    ///
    /// ⚠️ Vision's pixel space is bottom-left origin; SwiftUI's and CoreGraphics' image space are
    /// top-left. Flipping here, once, is why every consumer downstream — slot quantizing, the
    /// verification crop — can be plain arithmetic. `LensPhotoOverlay` paid for the same flip
    /// separately and getting it wrong puts every outline in the wrong half of the photo.
    func normalizedRect(in extent: CGRect) -> CGRect {
        guard extent.width > 0, extent.height > 0 else { return .zero }
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let minX = ((xs.min() ?? 0) - extent.minX) / extent.width
        let maxX = ((xs.max() ?? 0) - extent.minX) / extent.width
        let minY = ((ys.min() ?? 0) - extent.minY) / extent.height
        let maxY = ((ys.max() ?? 0) - extent.minY) / extent.height
        return CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
    }
}

/// Capture is always 2 pockets across by 2 down, whatever the binder — that is the geometry that
/// measured 63.3% auto-lock with zero wrong locks at 24.5 MP (§3). The binder's shape decides how
/// many photographs, never how much is in one.
enum BinderPlan {
    /// Pockets per axis in one photograph. Not a knob: 2 is the measured number.
    static let tileSide = 2

    /// A quad's ORB keypoint count must clear this to be a card at all. Phantom quads (glare bands,
    /// empty pockets, page edges) sit at a median of 15; a real card saturates the builder's 650.
    /// Belt-and-braces beside the one-card-per-pocket rule, and it costs one comparison (§6.3).
    static let minFpCount = 300

    /// Where each tile's window starts along one axis. `ceil(n / 2)` tiles, with the last shifted
    /// back so it stays inside the page — which is why a 3-wide binder sees its middle column twice
    /// and a 4-wide one sees nothing twice.
    ///
    /// The overlap is an asset: a pocket photographed twice gives two independent observations and
    /// the better one wins (`assign`). It costs nothing, because the shots are taken anyway.
    static func offsets(_ n: Int) -> [Int] {
        let count = (n + tileSide - 1) / tileSide
        return (0..<count).map { min($0 * tileSide, n - tileSide) }
    }

    /// Every photograph for one page, in the order they're asked for: reading order.
    static func tiles(shape: BinderShape, page: Int) -> [BinderTile] {
        offsets(shape.rows).flatMap { r in
            offsets(shape.cols).map { BinderTile(page: page, rowOffset: r, colOffset: $0) }
        }
    }

    /// What to call the tile on screen. Omits an axis that has only one tile, so a 2×2 binder is
    /// asked for "the whole page" rather than "the top-left of one tile".
    static func name(_ tile: BinderTile, shape: BinderShape) -> String {
        let down = label(tile.rowOffset, in: offsets(shape.rows), words: ["top", "middle", "bottom"])
        let across = label(tile.colOffset, in: offsets(shape.cols), words: ["left", "middle", "right"])
        let parts = [down, across].compactMap { $0 }
        return parts.isEmpty ? "the whole page" : parts.joined(separator: "-")
    }

    /// nil when the axis is one tile wide — there is nothing to disambiguate. With two tiles the
    /// middle word is skipped: "top"/"bottom", not "top"/"middle".
    private static func label(_ offset: Int, in offsets: [Int], words: [String]) -> String? {
        guard offsets.count > 1, let i = offsets.firstIndex(of: offset) else { return nil }
        return offsets.count == 2 ? (i == 0 ? words[0] : words[2]) : words[min(i, words.count - 1)]
    }

    /// Which pocket a detected card sits in. `centre` is normalized to the photograph, top-left
    /// origin — quantizing to the tile's 2×2 sub-grid is the whole of slot assignment.
    ///
    /// ⚠️ Every centre lands somewhere, deliberately. The frame is shot a little wider than exactly
    /// 2×2 (§5.3), so margin junk quantizes onto a pocket too — it is `assign` and `minFpCount`
    /// that throw it away, not this function. This one is only arithmetic.
    static func slot(centre: CGPoint, in tile: BinderTile) -> BinderSlot {
        BinderSlot(page: tile.page,
                   row: tile.rowOffset + (centre.y < 0.5 ? 0 : 1),
                   col: tile.colOffset + (centre.x < 0.5 ? 0 : 1))
    }

    /// Which pocket each detected card sits in, decided from **the cards' own geometry** rather than
    /// from the middle of the frame.
    ///
    /// ⚠️ Splitting the frame at 0.5 is what shipped, and it is wrong in the one way that matters: it
    /// assumes the four pockets are centred and fill the photograph. The guide deliberately tells the
    /// user to frame *wider* than the four pockets (§5.3), and a real shot is off-centre — so on a
    /// device, a whole page's bottom row landed in the top row's pockets and the real bottom row read
    /// as three empty pockets. The cards were identified correctly the whole time.
    ///
    /// Two cards in adjacent pockets are about one card apart centre-to-centre; two observations of the
    /// same pocket are near zero apart. So the cards themselves say where the dividing line is, and the
    /// frame's midpoint is only needed when there is nothing to compare against — a tile holding a
    /// single row, or a single column.
    ///
    /// `rects` are normalized to the photograph, top-left origin. The result is parallel to the input.
    ///
    /// ponytail: a midpoint split on one axis at a time, which cannot express a tile holding two rows
    /// where one row is shifted (a bowed page). Upgrade path is fitting the pocket pitch from the card
    /// size, which needs a slot-level measurement this project does not have yet.
    static func slots(rects: [CGRect], in tile: BinderTile) -> [BinderSlot] {
        let rows = split(rects.map { Double($0.midY) }, extents: rects.map { Double($0.height) })
        let cols = split(rects.map { Double($0.midX) }, extents: rects.map { Double($0.width) })
        return zip(rows, cols).map {
            BinderSlot(page: tile.page, row: tile.rowOffset + $0, col: tile.colOffset + $1)
        }
    }

    /// 0 or 1 per value, along one axis. Two groups when the values are spread further apart than a
    /// third of a card — anything less is one row (or one column) and falls back to the frame.
    private static func split(_ values: [Double], extents: [Double]) -> [Int] {
        guard !values.isEmpty else { return [] }
        let lo = values.min()!, hi = values.max()!
        // A third of a card: adjacent pockets sit ~1.0 apart, the same pocket ~0.0. Nothing real lands
        // between, so the exact fraction is not a tuning knob.
        let pitch = median(extents) * 0.35
        guard hi - lo > pitch else {
            // One row. Which one is genuinely unknowable from inside the tile, so the frame's midpoint
            // is the only evidence there is — and it is the same rule as before, now used only where
            // there is no better one.
            let centre = (lo + hi) / 2
            return values.map { _ in centre < 0.5 ? 0 : 1 }
        }
        let mid = (lo + hi) / 2
        return values.map { $0 < mid ? 0 : 1 }
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Resolves competing observations down to at most one card per pocket.
    ///
    /// This is the phantom filter, and it is free: the user told us there are exactly
    /// `rows × cols` pockets, so a 9-detection photograph of a 4-pocket window has 5 detections
    /// that cannot all be cards. Ranking by inlier count means a real card beats a glare band even
    /// when both quantize onto the same pocket — and it is also how the overlap between tiles
    /// becomes a vote rather than a conflict.
    ///
    /// `score` is the observation's inlier count; `fpCount` is its keypoint count. Ties break on
    /// `fpCount` so two unmatched observations still resolve deterministically.
    static func assign<T>(_ observations: [(slot: BinderSlot, score: Int, fpCount: Int, value: T)],
                          shape: BinderShape) -> [BinderSlot: T] {
        var best: [BinderSlot: (score: Int, fpCount: Int, value: T)] = [:]
        for o in observations {
            guard o.fpCount >= minFpCount,
                  (0..<shape.rows).contains(o.slot.row),
                  (0..<shape.cols).contains(o.slot.col) else { continue }
            if let held = best[o.slot], (held.score, held.fpCount) >= (o.score, o.fpCount) { continue }
            best[o.slot] = (o.score, o.fpCount, o.value)
        }
        return best.mapValues(\.value)
    }
}
