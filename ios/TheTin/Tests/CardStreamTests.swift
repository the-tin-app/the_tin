import XCTest
@testable import TheTin

final class CardStreamTests: XCTestCase {
    private func card(_ id: String) -> CardRecord {
        CardRecord(id: id, setId: "A", number: "1", name: id, hp: nil, types: [],
                   rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    /// A stream that returns overlapping pages; the pager must dedup.
    struct RepeatingStream: CardStream {
        let all: [CardRecord]
        func page(_ index: Int) -> [CardRecord] {
            // page 0 -> [a,b], page 1 -> [b,c] (overlap on b)
            index == 0 ? Array(all.prefix(2)) : Array(all.dropFirst().prefix(2))
        }
    }

    @MainActor
    func testPagerDedupsAcrossPages() async {
        let all = [card("a"), card("b"), card("c")]
        let pager = StreamPager(stream: RepeatingStream(all: all))
        await pager.loadNextPage()
        await pager.loadNextPage()
        XCTAssertEqual(pager.cards.map(\.id), ["a", "b", "c"], "duplicate 'b' dropped, order preserved")
    }

    /// A stream whose pages never overlap: page N -> exactly ["N"].
    struct NonOverlappingStream: CardStream {
        func page(_ index: Int) -> [CardRecord] {
            [CardRecord(id: "\(index)", setId: "A", number: "1", name: "\(index)", hp: nil,
                        types: [], rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)]
        }
    }

    /// Two concurrent loadNextPage() calls must NOT both fire: the `isLoading` guard rejects the
    /// second so exactly one page loads and the reserved index isn't skipped. (Regression: the old
    /// code read `nextIndex` before the await and both calls computed the same page, appending one
    /// page's worth while `nextIndex` jumped by 2 — permanently skipping the next page.)
    @MainActor
    func testConcurrentLoadDoesNotSkipPage() async {
        let pager = StreamPager(stream: NonOverlappingStream())
        async let a: Void = pager.loadNextPage()
        async let b: Void = pager.loadNextPage()
        _ = await (a, b)
        XCTAssertEqual(pager.cards.map(\.id), ["0"], "only one page loaded; second call rejected by guard")

        // The reserved index (1) was never consumed by a rejected call, so the very next load
        // fetches page 1 — no gap.
        await pager.loadNextPage()
        XCTAssertEqual(pager.cards.map(\.id), ["0", "1"], "next load fetches page 1, no page skipped")
    }
}
