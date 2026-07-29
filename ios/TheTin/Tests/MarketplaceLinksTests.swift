import XCTest
@testable import TheTin

final class MarketplaceLinksTests: XCTestCase {
    func testEbayCurrentEncodesQuery() throws {
        let url = MarketplaceLinks.ebayCurrent(name: "Pikachu & Zekrom", setName: "Team Up", number: "33")
        XCTAssertEqual(url.host, "www.ebay.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "_nkw" }?.value, "Pikachu & Zekrom Team Up 33")
        XCTAssertNil(items.first { $0.name == "LH_Sold" })
    }

    func testEbaySoldAddsSoldFiltersAndSkipsNilSetName() throws {
        let url = MarketplaceLinks.ebaySold(name: "Pikachu", setName: nil, number: "25")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "LH_Sold" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "LH_Complete" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "_nkw" }?.value, "Pikachu 25")
    }

    func testTcgplayerProductPageWhenIdKnown() {
        let url = MarketplaceLinks.tcgplayer(tcgplayerId: 88, name: "x", number: "1")
        XCTAssertEqual(url.host, "www.tcgplayer.com")
        XCTAssertEqual(url.path, "/product/88")
    }

    func testTcgplayerSearchFallbackWithoutId() throws {
        let url = MarketplaceLinks.tcgplayer(tcgplayerId: nil, name: "Pikachu", number: "025")
        XCTAssertTrue(url.path.contains("search"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Pikachu 025")
    }
}

extension MarketplaceLinksTests {
    private func items(_ url: URL) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }
    private func nkw(_ url: URL) throws -> String {
        try XCTUnwrap(items(url).first { $0.name == "_nkw" }?.value)
    }

    func testHuntQueryCarriesNameNumberAndSet() throws {
        let url = MarketplaceLinks.ebayHunt(name: "Charizard", setName: "Base Set", number: "4",
                                            total: "102", maxUsd: 300)
        let q = try nkw(url)
        XCTAssertTrue(q.contains("Charizard"))
        XCTAssertTrue(q.contains("4/102"))
        XCTAssertTrue(q.contains("Base Set"))
    }

    /// The literal list, NOT `for kw in huntNegativeKeywords` — iterating the same constant the
    /// URL is built from passes even if a keyword is deleted, which is how the far worse
    /// name-collision bug below survived review. Assert the content, not the mechanism.
    func testHuntQueryAppendsExactlyTheKnownNegativeKeywords() throws {
        XCTAssertEqual(MarketplaceLinks.huntNegativeKeywords,
                       ["proxy", "repro", "reproduction", "custom", "fake", "digital",
                        "lot", "bundle", "playtest", "orica", "metal", "sticker",
                        "fan art", "fanart",
                        "keychain", "magnet", "novelty", "jumbo", "display", "wooden",
                        "gold foil"])
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Charizard", setName: "Base Set",
                                                  number: "4", total: "102", maxUsd: nil))
        XCTAssertEqual(q, "Charizard 4/102 Base Set -proxy -repro -reproduction -custom -fake "
                        + "-digital -lot -bundle -playtest -orica -metal -sticker "
                        + "-\"fan art\" -fanart -keychain -magnet -novelty -jumbo -display "
                        + "-wooden -\"gold foil\"")
    }

    /// A phrase negative must reach eBay QUOTED. Bare `-fan art` is parsed as `-fan AND art`:
    /// it would require the word "art" in every listing and exclude Pokémon Fan Club outright.
    func testHuntQueryQuotesMultiWordNegatives() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Charizard", setName: "Base Set",
                                                  number: "4", total: "102", maxUsd: nil))
        XCTAssertTrue(q.contains("-\"fan art\""), "unquoted phrase negative: \(q)")
        XCTAssertFalse(q.contains("-fan art"), "bare phrase would AND \"art\": \(q)")
    }

    /// Sharing ONE word with a phrase negative is not a collision. "Pokémon Fan Club" is a real
    /// card; dropping -"fan art" for it would let fan art back into the one hunt most likely to
    /// surface it, and the old single-word rule is unchanged for every other keyword.
    func testHuntQueryKeepsAPhraseNegativeThatSharesOneWordWithTheName() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Pokemon Fan Club", setName: nil,
                                                  number: "83", total: nil, maxUsd: nil))
        XCTAssertTrue(q.contains("-\"fan art\""))
        XCTAssertTrue(q.contains("-fanart"))
    }

    /// The self-cancelling query. "Metal Energy" is a real, widely collected card, and
    /// `Metal Energy … -metal` excludes every listing that could possibly match — eBay reports
    /// that as an empty market. The colliding negative must be dropped, the rest kept.
    func testHuntQueryDropsANegativeThatCollidesWithTheCardName() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Metal Energy", setName: "Neo Genesis",
                                                  number: "19", total: "111", maxUsd: nil))
        XCTAssertTrue(q.contains("Metal Energy"))
        XCTAssertFalse(q.contains("-metal"), "self-cancelling query: \(q)")
        XCTAssertTrue(q.contains("-proxy"))   // every non-colliding negative survives
        XCTAssertTrue(q.contains("-fake"))
    }

    /// The set name is a required positive term too, so it cancels the query the same way.
    func testHuntQueryDropsANegativeThatCollidesWithTheSetName() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: "Custom Series",
                                                  number: "25", total: nil, maxUsd: nil))
        XCTAssertFalse(q.contains("-custom"))
        XCTAssertTrue(q.contains("-proxy"))
    }

    /// A substring is not a collision: "Metapod" must not suppress "-metal", or one long name
    /// would quietly strip the filters for every card sharing a prefix.
    func testHuntQueryKeepsNegativesThatOnlyLookLikeTheName() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Metapod", setName: nil, number: "54",
                                                  total: nil, maxUsd: nil))
        XCTAssertTrue(q.contains("-metal"))
    }

    /// The denominator is the token real seller titles carry ("Charizard 4/102"), and the bare
    /// number alone is ANDed against item counts, prices and "4 cards".
    func testDenominatorOnNumericNumbers() {
        XCTAssertEqual(MarketplaceLinks.denominator(number: "4", printedTotal: 102), "102")
        XCTAssertEqual(MarketplaceLinks.denominator(number: "025", printedTotal: 165), "165")
    }

    /// A promo number is already unique; "SWSH223/307" matches no real listing title.
    func testNoDenominatorForPromoNumbers() {
        XCTAssertNil(MarketplaceLinks.denominator(number: "SWSH223", printedTotal: 307))
        XCTAssertNil(MarketplaceLinks.denominator(number: "TG12", printedTotal: 30))
        XCTAssertNil(MarketplaceLinks.denominator(number: "", printedTotal: 102))
    }

    /// An unknown printed total means no denominator — never a guess, and never `SetRecord.total`
    /// (the catalog count is inflated past the printed denominator by secret rares, and a wrong
    /// denominator returns zero results silently).
    func testNoDenominatorWithoutAPrintedTotal() {
        XCTAssertNil(MarketplaceLinks.denominator(number: "4", printedTotal: nil))
    }

    func testHuntSetsBuyItNowAndCheapestFirst() throws {
        let i = try items(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil, number: "25",
                                                    total: nil, maxUsd: nil))
        XCTAssertEqual(i.first { $0.name == "LH_BIN" }?.value, "1")
        XCTAssertEqual(i.first { $0.name == "_sop" }?.value, "15")
    }

    /// The literal id, not the constant, for the same reason the keyword list is asserted
    /// literally: a wrong `_sacat` returns the wrong listings SILENTLY. 183454 is CCG Individual
    /// Cards, verified against live eBay 2026-07-29 — without it the top hit for Charizard 4/102
    /// was a $4.44 keychain, with it a $44.64 card.
    func testHuntIsScopedToTheSingleCardsCategory() throws {
        let i = try items(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil, number: "25",
                                                    total: nil, maxUsd: nil))
        XCTAssertEqual(i.first { $0.name == "_sacat" }?.value, "183454")
    }

    /// A counterfeit doesn't say so in its title, so the price is the only signal. A $12 listing
    /// for a $250 card is not a bargain.
    func testHuntFloorsThePriceAtAFractionOfMarket() throws {
        let i = try items(MarketplaceLinks.ebayHunt(name: "Charizard", setName: nil, number: "4",
                                                    total: nil, maxUsd: 300, marketUsd: 250))
        XCTAssertEqual(i.first { $0.name == "_udlo" }?.value, "62.50")
    }

    /// No market price, no floor — a guessed one is worse than none. Cards priced only in EUR
    /// or only as graded reach here with a nil raw price.
    func testHuntHasNoFloorWithoutAMarketPrice() throws {
        let i = try items(MarketplaceLinks.ebayHunt(name: "Charizard", setName: nil, number: "4",
                                                    total: nil, maxUsd: 300, marketUsd: nil))
        XCTAssertNil(i.first { $0.name == "_udlo" })
    }

    /// The floor must never cross the budget. Hunting well below market is the normal case, and
    /// `_udlo > _udhi` returns an empty page that reads as "none exist" — the exact lie about the
    /// market that the missing-ceiling rule above exists to prevent. The user's number wins.
    func testHuntDropsTheFloorWhenItWouldReachTheBudget() throws {
        let i = try items(MarketplaceLinks.ebayHunt(name: "Charizard", setName: nil, number: "4",
                                                    total: nil, maxUsd: 50, marketUsd: 250))
        XCTAssertNil(i.first { $0.name == "_udlo" }, "floor $62.50 above a $50 budget: empty page")
        XCTAssertEqual(i.first { $0.name == "_udhi" }?.value, "50")
    }

    /// Boundary: equal is still empty-ish, so equal must drop too.
    func testHuntPriceFloorRules() {
        XCTAssertEqual(MarketplaceLinks.priceFloor(marketUsd: 250, maxUsd: 300), 62.5)
        XCTAssertEqual(MarketplaceLinks.priceFloor(marketUsd: 250, maxUsd: nil), 62.5)
        XCTAssertNil(MarketplaceLinks.priceFloor(marketUsd: 250, maxUsd: 62.5))
        XCTAssertNil(MarketplaceLinks.priceFloor(marketUsd: 0, maxUsd: 300))
        XCTAssertNil(MarketplaceLinks.priceFloor(marketUsd: nil, maxUsd: 300))
    }

    /// The budget is the price ceiling. No budget means no ceiling — NOT a ceiling of 0,
    /// which would return an empty result page that reads as "none exist".
    func testHuntPriceCeilingPresentOnlyWithABudget() throws {
        let withBudget = try items(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil,
                                                             number: "25", total: nil, maxUsd: 300))
        XCTAssertEqual(withBudget.first { $0.name == "_udhi" }?.value, "300")

        let without = try items(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil,
                                                          number: "25", total: nil, maxUsd: nil))
        XCTAssertNil(without.first { $0.name == "_udhi" })
    }

    /// A ceiling of "300.0" is not what eBay wants, and "299.99" must survive intact.
    func testHuntPriceCeilingFormatting() throws {
        func ceiling(_ v: Double) throws -> String? {
            try items(MarketplaceLinks.ebayHunt(name: "x", setName: nil, number: "1",
                                                total: nil, maxUsd: v))
                .first { $0.name == "_udhi" }?.value
        }
        XCTAssertEqual(try ceiling(300), "300")
        XCTAssertEqual(try ceiling(299.99), "299.99")
        XCTAssertEqual(try ceiling(1234.5), "1234.50")
    }

    /// Card names carry apostrophes, ampersands and accents. URLComponents must escape them,
    /// and the raw query must survive a round trip unmangled.
    func testHuntQueryEscapesAwkwardNames() throws {
        let url = MarketplaceLinks.ebayHunt(name: "Farfetch'd & Sirfetch'd", setName: "Pokémon GO",
                                            number: "7", total: nil, maxUsd: nil)
        XCTAssertEqual(url.host, "www.ebay.com")
        let q = try nkw(url)
        XCTAssertTrue(q.contains("Farfetch'd & Sirfetch'd"))
        XCTAssertTrue(q.contains("Pokémon GO"))
    }

    /// Without a total there is no "4/102" to write — emit the bare number, never "4/".
    func testHuntNumberWithoutTotal() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil, number: "25",
                                                  total: nil, maxUsd: nil))
        XCTAssertTrue(q.contains("25"))
        XCTAssertFalse(q.contains("25/"))
    }

    /// A nil set name must not leave a double space or a stray token in the query.
    func testHuntWithoutSetNameHasNoDoubleSpace() throws {
        let q = try nkw(MarketplaceLinks.ebayHunt(name: "Pikachu", setName: nil, number: "25",
                                                  total: nil, maxUsd: nil))
        XCTAssertFalse(q.contains("  "))
    }

    /// The existing plain links must be untouched by the new one.
    func testPlainEbayCurrentStillHasNoHuntFilters() throws {
        let i = try items(MarketplaceLinks.ebayCurrent(name: "Pikachu", setName: nil, number: "25"))
        XCTAssertNil(i.first { $0.name == "LH_BIN" })
        XCTAssertNil(i.first { $0.name == "_udhi" })
    }
}
