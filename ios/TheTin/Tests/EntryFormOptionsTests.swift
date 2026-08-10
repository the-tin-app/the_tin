import XCTest
@testable import TheTin

final class EntryFormOptionsTests: XCTestCase {
    func testVariantsLimitedToCatalogPrintings() {
        let catalog = [VariantPrice(printing: "Normal", usd: 5)]
        XCTAssertEqual(EntryFormView.validVariants(catalog: catalog, current: nil), [.regular])
        // Holo + Reverse Holo priced → both offered, 1st Edition still not.
        let holos = [VariantPrice(printing: "Holofoil", usd: 40),
                     VariantPrice(printing: "Reverse Holofoil", usd: 12)]
        XCTAssertEqual(EntryFormView.validVariants(catalog: holos, current: nil), [.holo, .reverseHolo])
    }

    func testNoVariantDataOffersEverything() {
        XCTAssertEqual(EntryFormView.validVariants(catalog: [], current: nil), CardVariant.allCases)
    }

    func testSavedVariantAlwaysOffered() {
        // Entry saved as 1st Edition before the catalog stopped naming it — editing keeps it.
        let catalog = [VariantPrice(printing: "Normal", usd: 5)]
        XCTAssertEqual(EntryFormView.validVariants(catalog: catalog, current: .firstEdition),
                       [.regular, .firstEdition])
    }

    // offeredVariants is the "genuinely printed in" set — unlike validVariants it does NOT fold in
    // a current selection, so a caller can tell an impossible default from a real one. This is what
    // lets the staging review snap Tyranitar δ off its blind Regular default onto Holo/Reverse Holo.
    func testOfferedVariantsExcludesUnpricedFinishes() {
        let holos = [VariantPrice(printing: "Holofoil", usd: 40),
                     VariantPrice(printing: "Reverse Holofoil", usd: 12)]
        let offered = EntryFormView.offeredVariants(catalog: holos)
        XCTAssertEqual(offered, [.holo, .reverseHolo])
        XCTAssertFalse(offered.contains(.regular), "a holo-only card must not offer Regular")
    }

    func testOfferedVariantsFallsBackToAllWhenNoData() {
        XCTAssertEqual(EntryFormView.offeredVariants(catalog: []), CardVariant.allCases)
    }

    // The print-run axis: the catalog names runs ("Cosmos Holo", "World Championship Decks 2004")
    // as well as finishes. `.holo`'s substring test is true of "Cosmos Holo", which is exactly how
    // the old enum swallowed it — a collector could not record the card they actually owned.
    func testPrintRunIsOfferedAsItselfNotSwallowedByHolo() {
        let catalog = [VariantPrice(printing: "Cosmos Holo", usd: 3),
                       VariantPrice(printing: "Holofoil", usd: 40)]
        let offered = EntryFormView.offeredVariants(catalog: catalog)
        XCTAssertEqual(offered, [.holo, CardVariant(rawValue: "Cosmos Holo")!])
        XCTAssertEqual(offered.map(\.label), ["Holo", "Cosmos Holo"])
    }

    func testFinishesKeepTheirOrderAheadOfPrintRuns() {
        // Rows arrive cheapest-first from the catalog; the picker must not reorder itself by price.
        let catalog = [VariantPrice(printing: "World Championship Decks 2004", usd: 1),
                       VariantPrice(printing: "Reverse Holofoil", usd: 2),
                       VariantPrice(printing: "Normal", usd: 3)]
        XCTAssertEqual(EntryFormView.offeredVariants(catalog: catalog),
                       [.regular, .reverseHolo, CardVariant(rawValue: "World Championship Decks 2004")!])
    }

    func testSavedPrintRunSurvivesACatalogThatStopsNamingIt() {
        let run = CardVariant(rawValue: "Cosmos Holo")!
        XCTAssertEqual(EntryFormView.validVariants(catalog: [VariantPrice(printing: "Normal", usd: 5)],
                                                   current: run), [.regular, run])
    }
}

final class CardVariantPrintRunTests: XCTestCase {
    func testAPptFinishKeyCanonicalisesOntoItsFinish() {
        // Storage compatibility: "Holofoil" and "holo" must be the same value, or a CSV import
        // and a catalog printing would write two different strings for one finish.
        XCTAssertEqual(CardVariant(rawValue: "Holofoil"), .holo)
        XCTAssertEqual(CardVariant(rawValue: "Unlimited Holofoil"), .holo)
        XCTAssertEqual(CardVariant(rawValue: "1st Edition Holofoil"), .firstEdition)
        XCTAssertEqual(CardVariant(rawValue: "Normal"), .regular)
        XCTAssertEqual(CardVariant(rawValue: "holo"), .holo)
    }

    func testAPrintRunIsItsOwnValueAndMatchesOnlyItself() {
        let run = CardVariant(rawValue: "Cosmos Holo")!
        XCTAssertNotEqual(run, .holo)
        XCTAssertTrue(run.matches(printing: "Cosmos Holo"))
        XCTAssertFalse(run.matches(printing: "Holofoil"))
    }

    func testAPlainHoloIsNotValuedAtTheCheaperPromoPrice() {
        // Rows are cheapest-first, and `.holo.matches("Cosmos Holo")` is true — so the exact pass
        // in `row(in:)` is the only thing standing between a $40 holo and a $3 valuation.
        let catalog = [VariantPrice(printing: "Cosmos Holo", usd: 3),
                       VariantPrice(printing: "Holofoil", usd: 40)]
        XCTAssertEqual(CardVariant.holo.price(in: catalog), 40)
        XCTAssertEqual(CardVariant(rawValue: "Cosmos Holo")!.price(in: catalog), 3)
    }

    func testAPrintRunDeltaIsNotHandedToThePlainHoloCopy() {
        // `.printing` delta keys come from price_by_variant, so they carry print runs now, and
        // they arrive cheapest-first — the same trap as the price, one table over.
        let records = [DeltaRecord(kind: .printing, key: "Cosmos Holo", pct1d: -50, pct7d: nil, pct30d: nil),
                       DeltaRecord(kind: .printing, key: "Holofoil", pct1d: 10, pct7d: nil, pct30d: nil)]
        let entry = try! JSONDecoder().decode(CollectionEntry.self, from: Data("""
        {"id":"e","cardId":"swsh2-95","groupId":"","qty":1,"addedAt":0,"variant":"holo"}
        """.utf8))
        XCTAssertEqual(GroupStats.unitDelta(entry, records: records)?.key, "Holofoil")
    }

    func testACollectionJsonWrittenBeforePrintRunsStillDecodes() throws {
        // The storage claim in CardVariant's doc comment, asserted rather than asserted-in-prose.
        let json = Data("""
        {"id":"e","cardId":"ex1-74","groupId":"","qty":1,"addedAt":0,"variant":"holo"}
        """.utf8)
        let entry = try JSONDecoder().decode(CollectionEntry.self, from: json)
        XCTAssertEqual(entry.variantValue, .holo)
        let run = try JSONDecoder().decode(CollectionEntry.self, from: Data("""
        {"id":"e","cardId":"ex1-74","groupId":"","qty":1,"addedAt":0,"variant":"Cosmos Holo"}
        """.utf8))
        XCTAssertEqual(run.variantValue?.rawValue, "Cosmos Holo")
    }
}
