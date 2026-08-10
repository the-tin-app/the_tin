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
        XCTAssertEqual(t.pricedCards, 5)             // cover: "Valued: 5 of 6 cards" (2 psa10 + 3 raw)
        XCTAssertEqual(t.totalEntries, 3)
        XCTAssertEqual(t.totalCards, 6)              // Σ qty
        XCTAssertEqual(t.costBasis, 405)             // pricePaid is the ENTRY TOTAL — plain sum
    }

    func testSubtotalsPerDividerWithNoDividerLastAndEmptySkipped() {
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
        XCTAssertEqual(subs.map(\.name), ["Binder A", "Chase", "No divider"])
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
        XCTAssertEqual(rows[0].detail, "Holo · NM · Grade 10")      // only what's set
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

    // MARK: Sealed products

    private func product(_ id: Int, name: String, market: Double?) -> SealedProduct {
        SealedProduct(tcgplayerId: id, name: name, setId: "swsh7", productType: "Booster Box",
                      marketUsd: market, lowUsd: nil, asOf: "2026-07-04")
    }

    /// An insurance inventory lists what you HOLD, so a sold box is excluded — and rows sort by
    /// value, most valuable first, exactly as the card table does.
    func testSealedRowsExcludeSoldAndSortByValue() throws {
        let sealed = [
            SealedEntry(id: "cheap", productId: 2, qty: 1, addedAt: Date()),
            SealedEntry(id: "dear", productId: 1, qty: 2, pricePaid: 900,
                        acquiredFrom: "card show", addedAt: Date()),
            SealedEntry(id: "gone", productId: 1, qty: 1, addedAt: Date(), soldAt: Date()),
        ]
        let rows = InsuranceReport.sealedRows(sealed, products: [
            1: product(1, name: "Booster Box", market: 500),
            2: product(2, name: "Elite Trainer Box", market: 60),
        ])

        XCTAssertEqual(rows.map(\.id), ["dear", "cheap"])
        XCTAssertEqual(rows.first?.currentValue, 1000)      // 500 × 2
        XCTAssertEqual(rows.first?.pricePaid, 900)
        XCTAssertEqual(rows.first?.acquiredFrom, "card show")
    }

    /// A box this catalog can't price still PRINTS, named by its id. An inventory that drops the
    /// rows it can't value is exactly the wrong failure for an insurance document.
    func testSealedRowsKeepUnpricedProducts() throws {
        let sealed = [SealedEntry(id: "s1", productId: 999, qty: 1, pricePaid: 120, addedAt: Date())]
        let rows = InsuranceReport.sealedRows(sealed, products: [:])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Sealed product 999")
        XCTAssertNil(rows[0].currentValue)
        XCTAssertEqual(rows[0].pricePaid, 120)
    }

    /// Sealed adds its own page between the cards and the divider appendix — and adds none when
    /// there is no sealed, so a report for a card-only collection is exactly what it always was.
    @MainActor
    func testSealedAddsItsOwnPageAndNoneWhenEmpty() async throws {
        let entries = [entry("e1", card: "swsh7-215")]
        let prices = ["swsh7-215": rayPrice]
        let rows = InsuranceReport.rows(entries: entries, cards: ["swsh7-215": card("swsh7-215")],
                                        setNames: [:], prices: prices,
                                        variantsByCard: [:], conditionsByCard: [:])
        let totals = InsuranceReport.totals(entries: entries, prices: prices,
                                            variantsByCard: [:], conditionsByCard: [:])
        func pageCount(sealed: [SealedReportRow]) async throws -> Int {
            let pages = ReportPages.build(rows: rows, totals: totals, subtotals: [], images: [:],
                                          asOf: nil, contact: nil, sealed: sealed)
            let data = await SheetPDF.render(pages: pages)
            let doc = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
            return doc.numberOfPages
        }
        let sealed = InsuranceReport.sealedRows(
            [SealedEntry(id: "s1", productId: 1, qty: 1, addedAt: Date())],
            products: [1: product(1, name: "Booster Box", market: 500)])

        let without = try await pageCount(sealed: [])
        let with = try await pageCount(sealed: sealed)
        XCTAssertEqual(without, 3)      // cover + 1 table page + 1 appendix
        XCTAssertEqual(with, without + 1)
    }

    // MARK: Photo exhibit paging

    private func photoRow(_ id: String, photos: EntryPhotos?) -> ReportRow {
        ReportRow(id: id, card: nil, name: "Feraligatr", setLine: "Neo Genesis · #5",
                  detail: "Holo · NM", qty: 1, acquiredAt: nil, acquiredFrom: nil,
                  pricePaid: nil, currentValue: 12, photos: photos)
    }

    /// Nothing photographed ⇒ no exhibit pages and no markers, so a report for a collection with no
    /// photos is byte-identical to what it was before this feature.
    func testNoPhotosMeansNoExhibitPagesAndNoMarkers() {
        let rows = [photoRow("a", photos: nil), photoRow("b", photos: EntryPhotos())]
        let index = ReportPages.photoPageIndex(rowPages: 2, sealedPages: 0,
                                               photoRows: ReportPages.photoRows(rows))
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(ReportPages.photoRows(rows).isEmpty)
    }

    /// Four photographed entries at 3/page = 2 exhibit pages, starting after cover + rows + sealed.
    func testExhibitPagesFollowTheSealedSectionAndPackThreeToAPage() {
        let rows = (1...4).map { photoRow("e\($0)", photos: EntryPhotos(front: "f.jpg")) }
        let index = ReportPages.photoPageIndex(rowPages: 2, sealedPages: 1,
                                               photoRows: ReportPages.photoRows(rows))
        // page 1 cover, pages 2-3 inventory, page 4 sealed ⇒ exhibits start at 5.
        XCTAssertEqual(index["e1"], 5)
        XCTAssertEqual(index["e2"], 5)
        XCTAssertEqual(index["e3"], 5)
        XCTAssertEqual(index["e4"], 6)
    }

    func testPhotoRowsKeepsOnlyEntriesThatActuallyHaveFiles() {
        let rows = [photoRow("a", photos: EntryPhotos(front: "f.jpg")),
                    photoRow("b", photos: EntryPhotos()),
                    photoRow("c", photos: nil)]
        XCTAssertEqual(ReportPages.photoRows(rows).map(\.id), ["a"])
    }
}
