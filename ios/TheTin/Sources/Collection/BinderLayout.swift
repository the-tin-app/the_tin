import Foundation

/// Pockets on one page of a binder.
///
/// 1×1 (a solo showcase page) through 5×5, which covers the sheets people actually buy: 1, 4
/// (2×2), 9 (3×3), 12 (3×4).
///
/// ⚠️ Deliberately NOT the Lens's `BinderShape`, which clamps to 2...5 because a 2×2 *camera*
/// window has to fit inside a page. That clamp is asserted behaviour (`BinderPlanTests:11`) and
/// the type doubles as a persisted scan preference (`CatalogRemote:241`). A solo page is 1×1, so
/// reusing it would mean either breaking a tested invariant that exists for the camera or coupling
/// binder storage to a UserDefaults scan preference. Eight duplicated lines is the cheaper trade;
/// when the scanner learns to read a plan, `PageShape → BinderShape` is one line.
struct PageShape: Codable, Equatable, Hashable {
    var rows: Int
    var cols: Int

    static let range = 1...5
    static let `default` = PageShape(rows: 3, cols: 3)

    init(rows: Int, cols: Int) {
        self.rows = min(max(rows, Self.range.lowerBound), Self.range.upperBound)
        self.cols = min(max(cols, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Synthesized `Decodable` assigns stored properties directly and would bypass the clamp
    /// above, so a hand-edited `binders.json` could otherwise claim a 99×99 page.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rows: try c.decode(Int.self, forKey: .rows),
                  cols: try c.decode(Int.self, forKey: .cols))
    }

    var pockets: Int { rows * cols }
}

/// What you intend to put in a pocket. `variant == nil` means any printing of that card.
///
/// Extended art / SIR is its OWN `cardId` — special illustration rares carry their own collector
/// number — so this one key covers both the showcase page and the reverse-holo half of a master
/// set. There is no third case.
struct PlannedCard: Codable, Equatable, Hashable {
    var cardId: String
    /// `CardVariant` rawValue.
    var variant: String?
}

struct BinderPage: Codable, Equatable {
    /// nil = use the binder's default shape.
    var shape: PageShape?
    /// One element per pocket; nil = a pocket with nothing planned for it.
    var slots: [PlannedCard?]

    init(shape: PageShape? = nil, slots: [PlannedCard?] = []) {
        self.shape = shape
        self.slots = slots
    }

    func effectiveShape(default fallback: PageShape) -> PageShape { shape ?? fallback }
}

/// The layout of one divider, laid out as a binder. `groupId` IS the identity — a binder is a
/// divider that has a layout, not a separate object, so `CardGroup` keeps owning the name, the
/// sort order, the stats and the backup.
struct BinderLayout: Codable, Equatable, Identifiable {
    var id: String { groupId }
    var groupId: String
    var shape: PageShape = .default
    var pages: [BinderPage] = []

    /// Pocket count per page, in order.
    var capacities: [Int] { pages.map { $0.effectiveShape(default: shape).pockets } }

    /// Every page's slot array resized to its own shape.
    ///
    /// Applied on load and after a restore. `binders.json` and a restored backup are both trust
    /// boundaries, and a slot array shorter than its shape would index out of range in the view —
    /// which in this codebase means a fatal that takes the whole app (or the whole test suite) down.
    func normalized() -> BinderLayout {
        var copy = self
        for i in copy.pages.indices {
            let n = copy.pages[i].effectiveShape(default: shape).pockets
            var slots = copy.pages[i].slots
            if slots.count > n { slots = Array(slots.prefix(n)) }
            if slots.count < n { slots += Array(repeating: nil, count: n - slots.count) }
            copy.pages[i].slots = slots
        }
        return copy
    }

    /// The maximal run of consecutive default-shaped pages containing `page`.
    ///
    /// A page with its own shape is a wall — it is its own run, and no shift crosses it. That is
    /// what keeps a 1×1 showcase page from being pushed into by an insert eight pages earlier, and
    /// it reads correctly to a human: a page you deliberately shaped is a page you deliberately froze.
    func run(containing page: Int) -> Range<Int> {
        guard pages.indices.contains(page), pages[page].shape == nil else {
            return page..<(page + 1)
        }
        var lo = page, hi = page
        while lo > 0, pages[lo - 1].shape == nil { lo -= 1 }
        while hi + 1 < pages.count, pages[hi + 1].shape == nil { hi += 1 }
        return lo..<(hi + 1)
    }

    /// Pack a flat run of planned cards into default-shaped pages, padding the last one.
    static func chunk(_ flat: [PlannedCard?], shape: PageShape) -> [BinderPage] {
        guard shape.pockets > 0 else { return [] }
        var pages: [BinderPage] = []
        var cursor = 0
        while cursor < flat.count {
            var slots = Array(flat.dropFirst(cursor).prefix(shape.pockets))
            slots += Array(repeating: nil, count: shape.pockets - slots.count)
            pages.append(BinderPage(slots: slots))
            cursor += shape.pockets
        }
        return pages
    }
}
