import XCTest
@testable import TheTin

final class HuntingListViewTests: XCTestCase {
    private func card(number: String, name: String = "Charizard",
                      setId: String = "base1") -> CardRecord {
        CardRecord(id: "\(setId)-\(number)", setId: setId, number: number, name: name, hp: nil,
                   types: [], rarity: nil, artist: nil, imageBase: nil, imageUrl: nil,
                   tcgplayerId: nil)
    }
    private func hunting(target: Double? = 300) -> WantEntry {
        WantEntry(targetUsd: target, hunt: Hunt(minCondition: .hp, until: .distantFuture))
    }
    private func nkw(_ url: URL) throws -> String {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "_nkw" }?.value)
    }

    /// The whole point of the row's button. The denominator shipped as `nil` once — every hunt
    /// searched a bare "4", which eBay ANDs against item counts, prices and "4 cards" — so this
    /// asserts the value reaches the URL, not just that the builder can accept one.
    func testHuntURLCarriesThePrintedDenominator() throws {
        let url = try XCTUnwrap(HuntingListView.huntURL(card: card(number: "4"),
                                                        entry: hunting(),
                                                        setName: "Base Set", printedTotal: 102))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("4/102"), q)
    }

    /// Promo numbers are already unique, and "SWSH223/307" matches no real listing title.
    func testHuntURLOmitsTheDenominatorForAPromoNumber() throws {
        let url = try XCTUnwrap(HuntingListView.huntURL(card: card(number: "SWSH223",
                                                                  name: "Mewtwo V",
                                                                  setId: "swshp"),
                                                        entry: hunting(),
                                                        setName: "SWSH Black Star Promos",
                                                        printedTotal: 307))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("SWSH223"))
        XCTAssertFalse(q.contains("/307"), q)
    }

    /// An unknown printed total emits the bare number rather than guessing one — a wrong
    /// denominator returns zero results silently, which is worse than a loose query.
    func testHuntURLOmitsTheDenominatorWhenThePrintedTotalIsUnknown() throws {
        let url = try XCTUnwrap(HuntingListView.huntURL(card: card(number: "4"),
                                                        entry: hunting(),
                                                        setName: "Base Set", printedTotal: nil))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("4"))
        XCTAssertFalse(q.contains("4/"), q)
    }

    /// The budget is the price ceiling, and a card that isn't hunted has no row and no link.
    func testHuntURLPassesTheBudgetAndSkipsUnhuntedCards() throws {
        let url = try XCTUnwrap(HuntingListView.huntURL(card: card(number: "4"),
                                                        entry: hunting(target: 300),
                                                        setName: "Base Set", printedTotal: 102))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "_udhi" }?.value, "300")

        XCTAssertNil(HuntingListView.huntURL(card: card(number: "4"), entry: WantEntry(),
                                             setName: "Base Set", printedTotal: 102))
        XCTAssertNil(HuntingListView.huntURL(card: card(number: "4"), entry: nil,
                                             setName: "Base Set", printedTotal: 102))
    }
}
