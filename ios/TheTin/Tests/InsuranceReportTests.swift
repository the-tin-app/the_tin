import XCTest
import SwiftUI
import CoreGraphics
@testable import TheTin

final class InsuranceReportTests: XCTestCase {
    private let rayPrice = PriceRecord(cardId: "swsh7-215", rawUsd: 92.5, rawEur: 85.0, psa3: nil,
                                       psa7: nil, psa9: 180, psa10: 505, asOf: "2026-07-04")

    private func entry(_ id: String, card: String, group: String = "g1", qty: Int = 1,
                       grade: String? = nil, paid: Double? = nil, from: String? = nil,
                       acquired: Date? = nil) -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: group, qty: qty, condition: "NM",
                        grade: grade, pricePaid: paid, acquiredAt: acquired, acquiredFrom: from,
                        addedAt: Date(timeIntervalSince1970: 0), variant: nil)
    }

    private func card(_ id: String, set: String = "swsh7", number: String = "215",
                      name: String = "Rayquaza VMAX") -> CardRecord {
        CardRecord(id: id, setId: set, number: number, name: name, hp: nil, types: [], rarity: nil,
                   artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    func testTotalsCostBasisAndCoverage() {
        let prices = ["swsh7-215": rayPrice]
        let entries = [entry("e1", card: "swsh7-215", qty: 2, grade: "psa10", paid: 400),
                       entry("e2", card: "swsh7-12", paid: 5),      // unpriced but has cost
                       entry("e3", card: "swsh7-215", qty: 3)]      // no pricePaid
        let t = InsuranceReport.totals(entries: entries, prices: prices,
                                       variantsByCard: [:], conditionsByCard: [:])
        XCTAssertEqual(t.totalValue, 1010 + 277.5)   // 2×505 psa10 + 3×92.5 raw
        XCTAssertEqual(t.pricedEntries, 2)
        XCTAssertEqual(t.totalEntries, 3)            // cover: "Valued: 2 of 3 entries"
        XCTAssertEqual(t.totalCards, 6)              // Σ qty
        XCTAssertEqual(t.costBasis, 405)             // pricePaid is the ENTRY TOTAL — plain sum
    }

    func testSubtotalsPerDividerWithUnfiledLastAndEmptySkipped() {
        let groups = [CardGroup(id: "g1", name: "Binder A", sortOrder: 0, createdAt: .distantPast),
                      CardGroup(id: "g2", name: "Empty", sortOrder: 1, createdAt: .distantPast),
                      CardGroup(id: "g3", name: "Chase", sortOrder: 2, createdAt: .distantPast)]
        let entries = [entry("e1", card: "swsh7-215", group: "g1", qty: 2),
                       entry("e2", card: "swsh7-215", group: "g3"),
                       entry("e3", card: "swsh7-215", group: "", qty: 3)]   // ungrouped
        let subs = InsuranceReport.subtotals(entries: entries, groups: groups,
                                             prices: ["swsh7-215": rayPrice],
                                             variantsByCard: [:], conditionsByCard: [:])
        XCTAssertEqual(subs.map(\.id), ["g1", "g3", ""])          // tin order; empty g2 skipped
        XCTAssertEqual(subs.map(\.name), ["Binder A", "Chase", "Unfiled"])
        XCTAssertEqual(subs.map(\.cards), [2, 1, 3])
        XCTAssertEqual(subs[0].value, 185.0)                      // 2 × 92.5
    }

    func testRowsSortedValueDescendingWithHonestGaps() {
        let cards = ["swsh7-215": card("swsh7-215"),
                     "sv1-25": card("sv1-25", set: "sv1", number: "25", name: "Pikachu")]
        let prices = ["swsh7-215": rayPrice,
                      "sv1-25": PriceRecord(cardId: "sv1-25", rawUsd: 0.4, rawEur: nil, psa3: nil,
                                            psa7: nil, psa9: nil, psa10: nil, asOf: "2026-07-04")]
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var graded = entry("big", card: "swsh7-215", qty: 2, grade: "psa10", paid: 400,
                           from: "Card show", acquired: when)
        graded.variant = CardVariant.holo.rawValue
        let entries = [entry("cheap", card: "sv1-25"),
                       entry("ghost", card: "gone-1"),               // id missing from catalog
                       graded]
        let rows = InsuranceReport.rows(entries: entries, cards: cards,
                                        setNames: ["swsh7": "Evolving Skies"], prices: prices,
                                        variantsByCard: [:], conditionsByCard: [:])
        XCTAssertEqual(rows.map(\.id), ["big", "cheap", "ghost"])   // value desc, unpriced last
        XCTAssertEqual(rows[0].currentValue, 1010)                  // entry TOTAL (2 × psa10 505)
        XCTAssertEqual(rows[0].detail, "Holo · NM · PSA 10")        // only what's set
        XCTAssertEqual(rows[0].setLine, "Evolving Skies · #215")
        XCTAssertEqual(rows[0].pricePaid, 400)
        XCTAssertEqual(rows[0].acquiredFrom, "Card show")
        XCTAssertEqual(rows[0].acquiredAt, when)
        XCTAssertEqual(rows[1].setLine, "sv1 · #25")                // unnamed set → id fallback
        // Honest gaps: unresolved card prints its raw id, blank set line, nil value ("—").
        XCTAssertNil(rows[2].card)
        XCTAssertEqual(rows[2].name, "gone-1")
        XCTAssertEqual(rows[2].setLine, "")
        XCTAssertNil(rows[2].currentValue)
        XCTAssertNil(rows[2].pricePaid)
    }

    // Spec §Testing: PDF smoke test — fixture collection → expected page count, non-empty data.
    @MainActor
    func testFixtureCollectionRendersExpectedPageCount() async throws {
        let cards = ["swsh7-215": card("swsh7-215")]
        let prices = ["swsh7-215": rayPrice]
        let entries = (1...30).map { i in
            entry("e\(i)", card: i.isMultiple(of: 5) ? "swsh7-12" : "swsh7-215",
                  group: i.isMultiple(of: 2) ? "g1" : "g2")
        }
        let groups = [CardGroup(id: "g1", name: "Binder A", sortOrder: 0, createdAt: .distantPast),
                      CardGroup(id: "g2", name: "Chase", sortOrder: 1, createdAt: .distantPast)]
        let rows = InsuranceReport.rows(entries: entries, cards: cards, setNames: [:],
                                        prices: prices, variantsByCard: [:], conditionsByCard: [:])
        let totals = InsuranceReport.totals(entries: entries, prices: prices,
                                            variantsByCard: [:], conditionsByCard: [:])
        let subs = InsuranceReport.subtotals(entries: entries, groups: groups, prices: prices,
                                             variantsByCard: [:], conditionsByCard: [:])
        let pages = ReportPages.build(rows: rows, totals: totals, subtotals: subs, images: [:],
                                      asOf: "2026-07-04", contact: "Tomas Reyes")
        let data = await SheetPDF.render(pages: pages)
        XCTAssertFalse(data.isEmpty)
        let doc = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        XCTAssertEqual(doc.numberOfPages, 5)   // cover + ⌈30/14⌉=3 table pages + 1 appendix
    }
}
