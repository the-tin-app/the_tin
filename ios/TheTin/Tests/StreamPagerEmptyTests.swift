import XCTest
@testable import TheTin

private struct EmptyStream: CardStream { func page(_ index: Int) -> [CardRecord] { [] } }
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
}
