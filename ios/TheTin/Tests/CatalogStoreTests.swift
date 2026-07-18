import XCTest
@testable import TheTin

final class CatalogStoreTests: XCTestCase {
    private var store: CatalogStore!

    override func setUpWithError() throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
    }

    override func tearDownWithError() throws {
        try store?.close()
    }

    func testSetsOrderedNewestFirst() throws {
        let sets = try store.sets()
        // sv1 and svp share a release date; id breaks the tie. swsh7 (older) comes last.
        XCTAssertEqual(sets.map(\.id), ["sv1", "svp", "swsh7"])
        XCTAssertEqual(sets[2].name, "Evolving Skies")
        XCTAssertEqual(sets[2].total, 237)
        XCTAssertEqual(sets[2].era, "Sword & Shield")
    }

    func testCardsInSetOrderedByNumber() throws {
        let cards = try store.cards(inSet: "swsh7")
        // "TG20" sorts first: SQLite's CAST("TG20" AS INTEGER) is 0, lowest of the group.
        XCTAssertEqual(cards.map(\.number), ["TG20", "12", "94", "215"])
        let ray = cards[3]
        XCTAssertEqual(ray.name, "Rayquaza VMAX")
        XCTAssertEqual(ray.hp, 320)
        XCTAssertEqual(ray.types, ["Dragon"])
        XCTAssertEqual(ray.imageBase, "https://assets.tcgdex.net/en/swsh/swsh7/215")
    }

    func testPriceLookupAndGradeFallback() throws {
        let p = try XCTUnwrap(store.price(cardId: "swsh7-215"))
        XCTAssertEqual(p.rawUsd, 92.5)
        XCTAssertEqual(p.rawEur, 85.0)
        XCTAssertEqual(p.asOf, "2026-07-04")
        XCTAssertEqual(p.value(for: .psa10), 505)
        XCTAssertEqual(p.value(for: .psa3), 92.5)  // psa3 null → falls back to raw_usd
        XCTAssertEqual(p.value(for: nil), 92.5)
        XCTAssertNil(try store.price(cardId: "swsh7-12")) // coverage rule: no row
    }

    func testBatchPricesAndSetRawTotal() throws {
        let prices = try store.prices(cardIds: ["swsh7-215", "swsh7-94", "swsh7-12"])
        XCTAssertEqual(prices.count, 2)
        XCTAssertEqual(try store.setRawTotal(setId: "swsh7"), 122.6, accuracy: 0.001) // raw_usd 92.5 + 30.1
        XCTAssertEqual(try store.priceAsOf(), "2026-07-04")
        XCTAssertEqual(try store.cardCount(), 7)   // includes the sv1-025p promo fixture card
    }

    func testCardsByIds() throws {
        let cards = try store.cards(ids: ["sv1-25", "swsh7-94"])
        XCTAssertEqual(Set(cards.map(\.id)), ["sv1-25", "swsh7-94"])
    }

    func testImageURLPrefersTcgdexWebpThenFallsBackToImageUrl() throws {
        // `store` is the suite's fixture-backed CatalogStore from setUp.
        // Card with a tcgdex image_base → webp URL wins.
        let withBase = try XCTUnwrap(store.card(id: "swsh7-215"))
        XCTAssertEqual(withBase.imageURL(quality: "high")?.absoluteString, "https://assets.tcgdex.net/en/swsh/swsh7/215/high.webp")
        // Card with only a mirrored image_url → returned verbatim.
        let withUrl = try XCTUnwrap(store.card(id: "swsh7-12"))
        XCTAssertNil(withUrl.imageBase)
        XCTAssertEqual(withUrl.imageURL(quality: "high"), URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/fixture_in_800x800.jpg"))
    }

    func testPriceHistoryReturnsRowsAscendingAndEmptyWhenNone() throws {
        // `store` is the suite's fixture-backed CatalogStore from setUp.
        let points = try store.priceHistory(cardId: "swsh7-215")
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.value), [88.0, 90.5, 92.5]) // ascending by date
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(points.first?.date, fmt.date(from: "2026-01-05"))
        XCTAssertTrue(try store.priceHistory(cardId: "swsh7-12").isEmpty)
    }

    // (e) readers — printedTotal + twins, per task-E2-brief.md.
    func testPrintedTotalReadsSetInfoColumn() throws {
        XCTAssertEqual(try store.printedTotal(setId: FixtureCatalog.printedTotalSetId), FixtureCatalog.printedTotalValue)
        XCTAssertEqual(try store.printedTotal(setId: "sv1"), 198)
        XCTAssertNil(try store.printedTotal(setId: "no-such-set"))
    }

    func testTwinsReadsCardTwinTable() throws {
        let twins = try store.twins(cardId: FixtureCatalog.twinA)
        XCTAssertTrue(twins.contains(FixtureCatalog.twinB))
        XCTAssertTrue(try store.twins(cardId: "swsh7-12").isEmpty) // no twin row
    }
}
