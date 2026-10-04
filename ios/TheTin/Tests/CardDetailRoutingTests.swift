import XCTest
@testable import TheTin

/// Which printing card detail opens on — the half of "the row said +38%, the card said +1.2%"
/// that lives on the card's side. Rows are cheapest-first, like `price_by_variant`.
final class CardDetailRoutingTests: XCTestCase {
    private let printings = [VariantPrice(printing: "Cosmos Holo", usd: 3),
                             VariantPrice(printing: "Reverse Holofoil", usd: 12),
                             VariantPrice(printing: "Holofoil", usd: 40)]

    private func headline(_ variants: [VariantPrice], rarity: String? = "Rare Holo",
                          selected: String? = nil, highlighted: CardVariant? = nil) -> String? {
        CardDetailView.headlinePrinting(variants: variants, rarity: rarity, selected: selected,
                                        highlighted: highlighted)?.printing
    }

    /// A Movers row that quoted the reverse holo opens on the reverse holo, not the holo the
    /// rarity heuristic would pick.
    func testRoutedPrintingBeatsTheRarityDefault() {
        XCTAssertEqual(headline(printings, highlighted: .reverseHolo), "Reverse Holofoil")
    }

    /// `.holo` `matches` "Cosmos Holo" too, and it's the cheapest row — a first-match opened a
    /// plain holo copy on the $3 promo's price and change.
    func testAHoloCopyOpensOnTheHoloNotAPrintRunThatAlsoSaysHolo() {
        XCTAssertEqual(headline(printings, highlighted: .holo), "Holofoil")
    }

    /// Market rows carry PPT's key verbatim; it has to survive the trip through `CardVariant`.
    func testAPPTPrintingKeyRoundTripsThroughTheRoute() {
        let wotc = [VariantPrice(printing: "Unlimited Holofoil", usd: 90),
                    VariantPrice(printing: "1st Edition Holofoil", usd: 900)]
        XCTAssertEqual(headline(wotc, highlighted: CardVariant(rawValue: "1st Edition Holofoil")),
                       "1st Edition Holofoil")
        XCTAssertEqual(headline(printings, highlighted: CardVariant(rawValue: "Cosmos Holo")),
                       "Cosmos Holo")
    }

    /// Picking a printing on the screen wins over where you came from.
    func testTheUsersPickWinsOverTheRoute() {
        XCTAssertEqual(headline(printings, selected: "Holofoil", highlighted: .reverseHolo), "Holofoil")
    }

    /// A route naming a printing the card isn't priced in falls back to the old default.
    func testAnUnpricedRoutedPrintingFallsBackToTheDefault() {
        XCTAssertEqual(headline(printings, highlighted: .firstEdition), "Holofoil")
        XCTAssertEqual(headline(printings, rarity: "Rare", highlighted: nil), "Cosmos Holo",
                       "no regular printing → cheapest, as before")
    }

    /// One printing means no printing menu and no scoping — the headline is the raw market.
    func testASinglePrintingCardHasNoHeadlinePrinting() {
        XCTAssertNil(headline([VariantPrice(printing: "Holofoil", usd: 40)], highlighted: .holo))
    }

    /// A tin row routes with what its entry recorded; an entry that recorded neither routes plainly.
    func testATinRowRoutesWithWhatItsEntryRecorded() {
        func entry(variant: String?, condition: String?) -> CollectionEntry {
            CollectionEntry(id: "e", cardId: "c1", groupId: "", qty: 1, condition: condition,
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                            addedAt: Date(timeIntervalSince1970: 0), variant: variant)
        }
        let h = CardHighlight(entry: entry(variant: "reverseHolo", condition: "LP"))
        XCTAssertEqual(h?.printing, .reverseHolo)
        XCTAssertEqual(h?.condition, .lp)
        XCTAssertNil(CardHighlight(entry: entry(variant: nil, condition: nil)))
    }
}
