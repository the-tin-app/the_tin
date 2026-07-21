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
}
