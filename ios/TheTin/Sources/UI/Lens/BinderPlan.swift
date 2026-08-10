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
    /// Axis-aligned bounding box in the quad's own **pixel, bottom-left-origin** space — Vision's.
    /// No flip, no normalization: this is the space quads are built and consumed in.
    var boundingBox: CGRect {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Bounding box in coordinates normalized to `extent`, **top-left origin**.
    ///
    /// ⚠️ Vision's pixel space is bottom-left origin; SwiftUI's and CoreGraphics' image space are
    /// top-left. Flipping here, once, is why every consumer downstream — slot quantizing, the
    /// verification crop — can be plain arithmetic. Getting it wrong is not visibly an orientation
    /// bug: it puts the right cards in transposed pockets, which reads as a matching failure.
    func normalizedRect(in extent: CGRect) -> CGRect {
        guard extent.width > 0, extent.height > 0 else { return .zero }
        let b = boundingBox
        return CGRect(x: (b.minX - extent.minX) / extent.width,
                      y: 1 - (b.maxY - extent.minY) / extent.height,
                      width: b.width / extent.width,
                      height: b.height / extent.height)
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

    /// A card's short side, as a fraction of the photograph's short side, below which a quad is a
    /// phantom. Only needed for cells that have NO fingerprint to judge by — a card lost to glare or
    /// blur — because a keypoint floor would drop those and turn them into empty pockets.
    ///
    /// Principled rather than fitted: capture is always 2×2, so a card occupies about half the frame
    /// whatever the binder's shape. Measured over 179 real cells at 4032×3024 — every card-sized quad
    /// was ≥ 0.27 of the short side, every phantom ≤ 0.262, and nothing above 0.20 failed to fingerprint.
    static let minCardShortSideFraction = 0.20

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

    /// A zero-offset tile, so `slots` can be reused purely for its 0/1 sub-grid classification
    /// without inventing a second copy of that rule.
    private static let originTile = BinderTile(page: 0, rowOffset: 0, colOffset: 0)

    /// Quads for the pockets in this photograph that nothing was detected in, extrapolated from the
    /// cards that WERE detected. Pixel space, bottom-left origin — the space `quads` arrive in.
    ///
    /// ⚠️ **This is the only fix available for a corner pocket, and the reason is geometric.** Capture
    /// is 2×2, so exactly ONE tile window can ever contain a given corner of the page — a corner gets
    /// one look and there is no second observation to out-vote a detection miss. Measured on device
    /// 2026-08-09 over three 3×3 pages: coverage came out 4× centre / 2× edge-middles / **1× corners**,
    /// and all three positioned non-locks were corners. One of them (`p1 r3c1`) was detected by nothing
    /// at all — the tile that could see it returned three cells, not four — so the pocket rendered
    /// EMPTY, which is precisely the silent miss this feature exists to prevent.
    ///
    /// It is **self-calibrating, with no fitted constant**: the missing pocket's centre is read off the
    /// cards sharing its row and its column, and its size is the median of the cards actually present.
    /// So it works at any resolution, any binder shape and any framing — unlike a threshold tuned to
    /// one page, which the 08-08 handoff warns against by name.
    ///
    /// Two properties make it safe to add speculatively:
    ///   • **Both axes must be readable off cards that are really there.** A missing pocket is only
    ///     placed when some detected card shares its row (giving y) and some detected card shares its
    ///     column (giving x). Two cards in a single row therefore synthesise nothing, because the
    ///     other row's position is genuinely unknown rather than guessable.
    ///   • **It must identify to survive.** See `place` — a synthesised cell that does not resolve to a
    ///     card is discarded and its pocket reads empty.
    ///     ⚠️ **CORRECTED 2026-08-09.** This bullet used to claim the keypoint floor was the safeguard,
    ///     "a quad over a genuinely empty pocket fingerprints at ~15 keypoints against a real card's
    ///     saturated 650, so `minFpCount` throws it away". **That is false on real binders**: two empty
    ///     pockets measured 442 and 595 keypoints, because woven fabric and dot-textured sleeve plastic
    ///     are real texture. The ~15 figure came from glare bands, not from a framed empty pocket.
    ///     `minFpCount` cannot tell an empty pocket from a card; only the verdict can.
    ///
    /// Purely additive: nothing detected is dropped, so this cannot turn a read pocket into an unread
    /// one, and `assign` already ranks observations by inlier count — a weak synthetic loses to any
    /// real card that lands on the same pocket.
    static func missingPocketQuads(from quads: [CardQuad], extent: CGRect) -> [CardQuad] {
        // Two is the floor: one card gives a size but no pitch, so nothing can be placed from it.
        guard extent.width > 0, extent.height > 0, quads.count >= 2 else { return [] }
        let boxes = quads.map(\.boundingBox)
        let placed = slots(rects: quads.map { $0.normalizedRect(in: extent) }, in: originTile)
        let occupied = Set(placed)
        let w = median(boxes.map { Double($0.width) })
        let h = median(boxes.map { Double($0.height) })
        guard w > 0, h > 0 else { return [] }

        var out: [CardQuad] = []
        for row in 0..<tileSide {
            for col in 0..<tileSide {
                guard !occupied.contains(BinderSlot(page: 0, row: row, col: col)) else { continue }
                let ys = zip(placed, boxes).filter { $0.0.row == row }.map { Double($0.1.midY) }
                let xs = zip(placed, boxes).filter { $0.0.col == col }.map { Double($0.1.midX) }
                guard !ys.isEmpty, !xs.isEmpty else { continue }
                let rect = CGRect(x: median(xs) - w / 2, y: median(ys) - h / 2, width: w, height: h)
                // A pocket extrapolated off the edge of the photograph cannot be rectified, and a
                // card hanging out of frame could not have been read anyway.
                guard extent.contains(rect) else { continue }
                out.append(CardQuad(topLeft: CGPoint(x: rect.minX, y: rect.maxY),
                                    topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                                    bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
                                    bottomRight: CGPoint(x: rect.maxX, y: rect.minY)))
            }
        }
        return out
    }

    /// One observation of one pocket: which cell, where in the frame, and which pocket it lands in.
    struct Placed {
        let cell: LensCell
        /// Normalized to the photograph, top-left origin — what the verification crop is cut from.
        let rect: CGRect
        let slot: BinderSlot
    }

    /// Every photograph's detections → pockets, phantoms dropped. The shared step between what the
    /// device does (`BinderModel.assignSlots`) and what the replay harness measures, so a
    /// measurement cannot drift from the shipped behaviour by re-implementing this.
    ///
    /// ⚠️ Phantoms are excluded BEFORE the sub-grid is worked out, not after. `slots` decides where the
    /// dividing line falls from the spread of what it is given, so one glare band at the edge of the
    /// frame would drag that line and mis-row every real card with it.
    ///
    /// ⚠️ And `.unreadable` cells are KEPT, which `fpCount` alone cannot express — a card lost to
    /// glare or too blurred to fingerprint has no keypoints at all, so a keypoint floor drops it and
    /// the pocket renders as EMPTY. "There is nothing in this pocket" and "there is a card here I
    /// could not read" are different answers, and quietly giving the first one is the silent miss this
    /// whole feature exists to avoid.
    static func place(cells: [LensCell], tile: BinderTile, extent: CGRect) -> [Placed] {
        let rects = cells.map { $0.quad.normalizedRect(in: extent) }
        let short = min(extent.width, extent.height)
        let keep = zip(cells, rects).filter { cell, rect in
            // ⚠️ A synthesised quad is a GUESS that a pocket is occupied, so it must earn its place by
            // actually identifying. Anything less is discarded and the pocket reads empty, which is the
            // truth.
            //
            // The keypoint floor cannot do this job, and device data on 2026-08-09 is why: two EMPTY
            // pockets on page 4 produced synthesised quads fingerprinting at **442 and 595** keypoints,
            // against the ~15 this file's own comment attributes to a phantom. That figure came from
            // glare bands and page edges; a well-framed empty sleeve is woven fabric and dot-textured
            // plastic, which is real texture. Both came back `noMatch` — so no card was invented — but
            // both pockets rendered as "there is a card here I could not read", which is precisely the
            // dishonest answer the phantom filter exists to prevent.
            //
            // Deliberately requires `.identified` and not merely "not noMatch": offering a four-way
            // chooser for a pocket that may be empty is the same lie with extra steps.
            if cell.synthesized { return cell.resolvedCardId != nil }
            if cell.fpCount >= minFpCount { return true }
            guard cell.isUnreadable else { return false }
            // No fingerprint to judge by, so judge by size — and because capture is ALWAYS 2×2, a card
            // occupies about half the frame whatever the binder's shape, which makes a fraction of the
            // frame a principled test rather than a fitted one. Measured over 179 real cells: every
            // card-sized quad was ≥ 0.27 of the frame's short side and every phantom ≤ 0.262, and
            // nothing above 0.20 failed to fingerprint at all.
            return min(rect.width * extent.width, rect.height * extent.height)
                >= short * minCardShortSideFraction
        }
        let keptRects = keep.map(\.1)
        return zip(keep, slots(rects: keptRects, in: tile)).map {
            Placed(cell: $0.0.0, rect: $0.0.1, slot: $0.1)
        }
    }

    /// Resolves competing observations down to at most one card per pocket.
    ///
    /// At most one is free: the user told us there are exactly `rows × cols` pockets, so a
    /// 9-detection photograph of a 4-pocket window has 5 detections that cannot all be cards. Ranking
    /// by inlier count means a real card beats a glare band even when both quantize onto the same
    /// pocket — and it is also how the overlap between tiles becomes a vote rather than a conflict.
    ///
    /// ⚠️ **The phantom filter is deliberately NOT here.** It used to be, as a keypoint floor, and
    /// that quietly re-dropped every `.unreadable` cell the caller had just gone to the trouble of
    /// keeping — a card lost to glare has no keypoints at all, so a floor here turned it back into an
    /// empty pocket two lines after `BinderModel.assignSlots` decided it was a card. Deciding what is
    /// a card needs to know the cell's STATE, which only the caller has, so it belongs there and
    /// nowhere else.
    ///
    /// `score` is the observation's inlier count; `fpCount` breaks ties, so two unmatched observations
    /// still resolve deterministically.
    static func assign<T>(_ observations: [(slot: BinderSlot, score: Int, fpCount: Int, value: T)],
                          shape: BinderShape) -> [BinderSlot: T] {
        var best: [BinderSlot: (score: Int, fpCount: Int, value: T)] = [:]
        for o in observations {
            guard (0..<shape.rows).contains(o.slot.row),
                  (0..<shape.cols).contains(o.slot.col) else { continue }
            if let held = best[o.slot], (held.score, held.fpCount) >= (o.score, o.fpCount) { continue }
            best[o.slot] = (o.score, o.fpCount, o.value)
        }
        return best.mapValues(\.value)
    }
}
