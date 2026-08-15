import XCTest
@testable import TheTin

private struct EmptyStream: CardStream { func page(_ index: Int) -> [CardRecord] { [] } }

private func card(_ id: String) -> CardRecord {
    CardRecord(id: id, setId: "s", number: "1", name: id, hp: nil, types: [],
               rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
}

/// Serves prepared pages in order, then runs dry.
private struct FixedStream: CardStream {
    let pages: [[CardRecord]]
    func page(_ index: Int) -> [CardRecord] { index < pages.count ? pages[index] : [] }
}
private struct OneCardStream: CardStream {
    func page(_ index: Int) -> [CardRecord] {
        index == 0 ? [CardRecord(id: "x", setId: "s", number: "1", name: "X", hp: nil, types: [],
                                 rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)] : []
    }
}

@MainActor
final class StreamPagerEmptyTests: XCTestCase {
    func testEmptyResultAfterEmptyPage() async {
        let pager = StreamPager(stream: EmptyStream())
        XCTAssertFalse(pager.isEmptyResult) // nothing loaded yet
        await pager.loadNextPage()
        XCTAssertTrue(pager.isEmptyResult)  // a page loaded, zero cards
    }

    func testNotEmptyWhenCardsPresent() async {
        let pager = StreamPager(stream: OneCardStream())
        await pager.loadNextPage()
        XCTAssertFalse(pager.isEmptyResult)
    }

    /// ⚠️ **Reported by a user: "it seems to do nothing."** Thumbing a card down recorded the
    /// dismissal and rebuilt the shelves behind — but the deck holds its own loaded `cards` array,
    /// so the card in front of you never moved. An action with no visible consequence reads as a
    /// broken button, however correct the bookkeeping underneath.
    @MainActor
    func testRemovingACardTakesItOutOfTheDeck() async {
        let pager = StreamPager(stream: FixedStream(pages: [[card("a"), card("b"), card("c")]]))
        await pager.loadNextPage()
        XCTAssertEqual(pager.cards.map(\.id), ["a", "b", "c"])

        pager.remove("b")
        XCTAssertEqual(pager.cards.map(\.id), ["a", "c"])
    }

    /// A rejected card must not reappear on a later page — it stays in `seen`.
    @MainActor
    func testARemovedCardDoesNotComeBackOnTheNextPage() async {
        let pager = StreamPager(stream: FixedStream(pages: [[card("a"), card("b")],
                                                            [card("b"), card("c")]]))
        await pager.loadNextPage()
        pager.remove("b")
        await pager.loadNextPage()
        XCTAssertEqual(pager.cards.map(\.id), ["a", "c"], "b was rejected and must stay gone")
    }

    @MainActor
    func testRemovingSomethingAbsentIsHarmless() async {
        let pager = StreamPager(stream: FixedStream(pages: [[card("a")]]))
        await pager.loadNextPage()
        pager.remove("nope")
        XCTAssertEqual(pager.cards.map(\.id), ["a"])
    }
}
