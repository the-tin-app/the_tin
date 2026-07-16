import XCTest
@testable import TheTin

final class GroupStatsTests: XCTestCase {
    private let rayPrice = PriceRecord(cardId: "swsh7-215", rawUsd: 92.5, rawEur: 85.0, psa3: nil, psa7: nil,
                                       psa9: 180, psa10: 505, asOf: "2026-07-04")

    private func entry(_ id: String, card: String, qty: Int = 1, grade: String? = nil,
                       variant: CardVariant? = nil, condition: String = "NM") -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "g1", qty: qty, condition: condition, grade: grade,
                        pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date(timeIntervalSince1970: 0),
                        variant: variant?.rawValue)
    }

    func testEntryValueUsesGradeThenFallsBackToRaw() {
        XCTAssertEqual(GroupStats.entryValue(entry("e1", card: "swsh7-215", qty: 2, grade: "psa10"), price: rayPrice), 1010)
        XCTAssertEqual(GroupStats.entryValue(entry("e2", card: "swsh7-215", grade: "psa3"), price: rayPrice), 92.5)
        XCTAssertEqual(GroupStats.entryValue(entry("e3", card: "swsh7-215"), price: rayPrice), 92.5)
        XCTAssertNil(GroupStats.entryValue(entry("e4", card: "swsh7-12"), price: nil))
    }

    func testRawEntryPricesByOwnedPrinting() {
        // Rayquaza's printings: Normal $10, Reverse Holofoil $140. A raw reverse-holo values at the
        // reverse printing, NOT the headline raw_usd ($92.5). Graded still uses the PSA column.
        let variants = [VariantPrice(printing: "Normal", usd: 10),
                        VariantPrice(printing: "Reverse Holofoil", usd: 140)]
        XCTAssertEqual(GroupStats.entryValue(entry("rev", card: "swsh7-215", qty: 2, variant: .reverseHolo),
                                             price: rayPrice, variants: variants), 280)   // 140 × 2
        XCTAssertEqual(GroupStats.entryValue(entry("norm", card: "swsh7-215", variant: .regular),
                                             price: rayPrice, variants: variants), 10)
        // Owned printing not priced (no Holofoil row) → falls back to raw_usd.
        XCTAssertEqual(GroupStats.entryValue(entry("holo", card: "swsh7-215", variant: .holo),
                                             price: rayPrice, variants: variants), 92.5)
        // Graded ignores variants entirely.
        XCTAssertEqual(GroupStats.entryValue(entry("g", card: "swsh7-215", grade: "psa10", variant: .reverseHolo),
                                             price: rayPrice, variants: variants), 505)
        // No variant prices at all → raw_usd (today's behavior preserved).
        XCTAssertEqual(GroupStats.entryValue(entry("x", card: "swsh7-215", variant: .reverseHolo),
                                             price: rayPrice), 92.5)
    }

    func testRawEntryPricesByCondition() {
        // A played entry uses its condition's market price — NOT the printing or raw_usd. This is
        // the "selected DMG + regular but saw the 1st Edition NM price" bug: no "Normal" printing
        // exists, so the old code fell through to raw_usd (the 1st Ed market price).
        let conditions = [ConditionPrice(condition: .nearMint, usd: 90),
                          ConditionPrice(condition: .damaged, usd: 12)]
        let variants = [VariantPrice(printing: "Unlimited Holofoil", usd: 100),
                        VariantPrice(printing: "1st Edition Holofoil", usd: 400)]
        XCTAssertEqual(GroupStats.entryValue(entry("dmg", card: "base1-4", variant: .regular, condition: "DMG"),
                                             price: rayPrice, variants: variants, conditions: conditions), 12)
        // NM keeps the owned printing's price; the condition table doesn't override it.
        XCTAssertEqual(GroupStats.entryValue(entry("nm", card: "base1-4", variant: .holo),
                                             price: rayPrice, variants: variants, conditions: conditions), 100)
        // Condition set but unpriced → printing → raw fallback chain still applies.
        XCTAssertEqual(GroupStats.entryValue(entry("lp", card: "base1-4", variant: .firstEdition, condition: "LP"),
                                             price: rayPrice, variants: variants, conditions: conditions), 400)
        // No raw_usd at all → NM condition price backstops.
        let noRaw = PriceRecord(cardId: "base1-4", rawUsd: nil, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-04")
        XCTAssertEqual(GroupStats.entryValue(entry("bare", card: "base1-4"),
                                             price: noRaw, conditions: conditions), 90)
    }

    func testIsPricedExactlyRequiresTheRecordedConditionsOwnRow() {
        let conditions = [ConditionPrice(condition: .nearMint, usd: 90),
                          ConditionPrice(condition: .damaged, usd: 12)]
        // DMG has its own row → exact.
        XCTAssertTrue(GroupStats.isPricedExactly(entry("dmg", card: "base1-4", condition: "DMG"),
                                                 price: rayPrice, conditions: conditions))
        // LP has no row of its own — entryValue still estimates via fallback, but that's not exact.
        XCTAssertFalse(GroupStats.isPricedExactly(entry("lp", card: "base1-4", condition: "LP"),
                                                  price: rayPrice, conditions: conditions))
        // NM/unspecified always counts as exact as long as *some* price resolves.
        XCTAssertTrue(GroupStats.isPricedExactly(entry("nm", card: "base1-4"), price: rayPrice, conditions: conditions))
        // No price at all → never exact.
        XCTAssertFalse(GroupStats.isPricedExactly(entry("none", card: "base1-4"), price: nil))
    }

    func testTotalValueEstimatesFallbackEntriesButOnlyCountsExactOnes() {
        // Spec §5.2: the aggregate is a best-effort ESTIMATE — a DMG entry with no
        // price_by_condition row still contributes its fallback estimate to the total (matching
        // the portfolio series, which scales the same estimate), but is not counted as "priced".
        let conditions = ["base1-4": [ConditionPrice(condition: .nearMint, usd: 90)]]
        let prices = ["base1-4": rayPrice]
        let entries = [entry("dmg", card: "base1-4", condition: "DMG"), entry("nm", card: "base1-4")]
        let result = GroupStats.totalValue(entries: entries, prices: prices, conditionsByCard: conditions)
        XCTAssertEqual(result.pricedEntries, 1)   // only the NM entry is exactly priced
        XCTAssertEqual(result.totalEntries, 2)
        XCTAssertEqual(result.total, 185.0)       // both entries estimate at rawUsd 92.5
    }

    func testRegularMatchesUnlimitedPrinting() {
        // WotC-era keys: "Unlimited" (non-holo) is the regular printing; "Unlimited Holofoil" is holo.
        let wotc = [VariantPrice(printing: "Unlimited", usd: 25),
                    VariantPrice(printing: "1st Edition", usd: 250)]
        XCTAssertEqual(CardVariant.regular.price(in: wotc), 25)
        XCTAssertEqual(CardVariant.firstEdition.price(in: wotc), 250)
        XCTAssertEqual(CardVariant.holo.price(in: [VariantPrice(printing: "Unlimited Holofoil", usd: 100)]), 100)
        XCTAssertNil(CardVariant.regular.price(in: [VariantPrice(printing: "Unlimited Holofoil", usd: 100)]))
    }

    func testTotalValueReportsCoverage() {
        let prices = ["swsh7-215": rayPrice]
        let entries = [entry("e1", card: "swsh7-215", qty: 2), entry("e2", card: "swsh7-12")]
        let result = GroupStats.totalValue(entries: entries, prices: prices)
        XCTAssertEqual(result.total, 185.0)
        XCTAssertEqual(result.pricedEntries, 1)
        XCTAssertEqual(result.totalEntries, 2)
    }

    func testCardCountSumsQuantities() {
        let entries = [entry("e1", card: "swsh7-215", qty: 3), entry("e2", card: "swsh7-12")]
        XCTAssertEqual(entries.cardCount, 4)
    }

    func testSortByValueDescendingUnpricedLast() {
        let prices = ["swsh7-215": rayPrice,
                      "sv1-25": PriceRecord(cardId: "sv1-25", rawUsd: 0.4, rawEur: 0.35, psa3: nil, psa7: nil,
                                            psa9: nil, psa10: 15, asOf: "2026-07-04")]
        let entries = [entry("cheap", card: "sv1-25"), entry("none", card: "swsh7-12"),
                       entry("big", card: "swsh7-215")]
        XCTAssertEqual(GroupStats.sortedByValueDescending(entries: entries, prices: prices).map(\.id),
                       ["big", "cheap", "none"])
    }

    func testUnitPriceForDraftShapedInput() {
        // A ScanDraft is not a CollectionEntry: it has a non-optional variant + condition and no
        // grade/qty. Same fixtures as the entry tests above so the resolution provably matches.
        let variants = [VariantPrice(printing: "Normal", usd: 10),
                        VariantPrice(printing: "Reverse Holofoil", usd: 140)]
        let conditions = [ConditionPrice(condition: .nearMint, usd: 90),
                          ConditionPrice(condition: .damaged, usd: 12)]
        // Variant set (NM condition): the owned printing's price, not raw_usd.
        XCTAssertEqual(GroupStats.unitPrice(condition: .nm, variant: .reverseHolo,
                                            price: rayPrice, variants: variants), 140)
        // Non-NM condition set and priced: condition price wins over the printing.
        XCTAssertEqual(GroupStats.unitPrice(condition: .dmg, variant: .reverseHolo,
                                            price: rayPrice, variants: variants, conditions: conditions), 12)
        // Condition set but unpriced (no LP row) → printing price still applies.
        XCTAssertEqual(GroupStats.unitPrice(condition: .lp, variant: .reverseHolo,
                                            price: rayPrice, variants: variants, conditions: conditions), 140)
        // Selected printing unpriced (no Holofoil row) → raw_usd fallback.
        XCTAssertEqual(GroupStats.unitPrice(condition: .nm, variant: .holo,
                                            price: rayPrice, variants: variants), 92.5)
        // No price data at all → nil (row shows "—").
        XCTAssertNil(GroupStats.unitPrice(condition: .nm, variant: .regular, price: nil))
        // No raw_usd → NM condition price backstops.
        let noRaw = PriceRecord(cardId: "base1-4", rawUsd: nil, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-04")
        XCTAssertEqual(GroupStats.unitPrice(condition: .nm, variant: .holo,
                                            price: noRaw, conditions: conditions), 90)
        // Graded input (entry-shaped) uses the PSA column and ignores variants.
        XCTAssertEqual(GroupStats.unitPrice(grade: .psa10, condition: .nm, variant: .reverseHolo,
                                            price: rayPrice, variants: variants), 505)
    }

    func testSetCompletionCountsDistinctNumbers() {
        let setCards = [
            CardRecord(id: "swsh7-215", setId: "swsh7", number: "215", name: "Rayquaza VMAX", hp: 320,
                       types: [], rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil),
            CardRecord(id: "swsh7-94", setId: "swsh7", number: "94", name: "Umbreon V", hp: 200,
                       types: [], rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil),
        ]
        let entries = [entry("e1", card: "swsh7-215", qty: 3), entry("e2", card: "swsh7-215"),
                       entry("e3", card: "swsh7-94"), entry("e4", card: "sv1-1")]
        let completion = GroupStats.setCompletion(entries: entries, setCards: setCards, setTotal: 237)
        XCTAssertEqual(completion.owned, 2)   // 215 and 94, dupes and other sets ignored
        XCTAssertEqual(completion.total, 237)
    }
}
