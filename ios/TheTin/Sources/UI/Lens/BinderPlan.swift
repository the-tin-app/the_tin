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
struct BinderSlot: Hashable, Codable, Comparable {
    let page: Int
    let row: Int
    let col: Int

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
