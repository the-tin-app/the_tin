import Foundation

/// How many cards one page of the deck shows. The deck stays a deck at every density — same
/// horizontal paging, same snap, same chevrons — only the contents of a page change.
///
/// Deliberately just two values. 3×3 was considered and dropped: on a phone it lands at ~130pt
/// tiles, smaller than the set grid already does better, and it is nine concurrent high-quality
/// decodes on a device where `ImageCache.maxConcurrentDownloads` is 4.
enum StreamDensity: Int, CaseIterable, Identifiable {
    case one = 1
    case four = 4

    var id: Int { rawValue }
    var columns: Int { self == .one ? 1 : 2 }
    var label: String { self == .one ? "One card" : "Grid" }
    var symbol: String { self == .one ? "rectangle.portrait" : "square.grid.2x2" }

    /// One `@AppStorage` key, app-wide — the same convention `DeltaPeriod` uses. Density is a
    /// property of how you like to browse, not of which stream you happen to be in.
    static let storageKey = "streamDensity"

    /// Cards per page. Named rather than `rawValue` at call sites so the arithmetic reads.
    var pageSize: Int { rawValue }

    /// Pages needed for `count` cards, rounding up — a trailing partial page is a real page.
    func pageCount(cardCount: Int) -> Int {
        guard cardCount > 0 else { return 0 }
        return (cardCount + pageSize - 1) / pageSize
    }

    /// Card indices on one page, clamped to what actually exists so the last page can be short.
    func cardRange(page: Int, cardCount: Int) -> Range<Int> {
        let start = min(page * pageSize, cardCount)
        return start..<min(start + pageSize, cardCount)
    }

    /// Where to land after a density change, so the card you were looking at stays on screen.
    /// Without this, switching 1-up → grid at card 40 jumps to page 40 (card 160) and reads as
    /// the deck losing your place.
    func remapPage(_ page: Int, from old: StreamDensity) -> Int {
        let firstCard = page * old.pageSize
        return firstCard / pageSize
    }

    /// Card indices to warm ahead of `page`.
    ///
    /// ⚠️ Counted in PAGES, not cards, and deliberately shallow. The old code warmed `index + 5`
    /// when a page was one card; at 2×2 the same constant would put **20 images** in flight
    /// against `maxConcurrentDownloads` of 4 on an A10 — the exact axis the Connections jetsam
    /// crash lived on. Higher density also means longer dwell per page, so less lookahead is
    /// needed, not more.
    func prefetchRange(page: Int, cardCount: Int, pagesAhead: Int = 2) -> Range<Int> {
        let start = min(page * pageSize, cardCount)
        let end = min(start + pageSize * pagesAhead, cardCount)
        return start..<end
    }
}
