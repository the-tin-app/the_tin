import XCTest
import GRDB
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
        XCTAssertEqual(ray.attacks, [Attack(name: "Max Burst", damage: "320", cost: ["Fire", "Lightning"])])
        XCTAssertEqual(cards[2].attacks, []) // NULL attacks column → empty, never a decode crash
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

    func testPriceRecordReadsAllPsaColumns() throws {
        // Fixture: Rayquaza has psa7/psa9/psa10 but no psa8 (the interpolation gap card).
        let p = try XCTUnwrap(try store.price(cardId: "swsh7-215"))
        XCTAssertEqual(p.psa7, 90)
        XCTAssertNil(p.psa8)
        XCTAssertEqual(p.psa9, 180)
        XCTAssertEqual(p.gradedOnly(.psa8), nil)
        XCTAssertEqual(p.gradedOnly(.psa9), 180)
        XCTAssertEqual(p.value(for: .psa8), 92.5)  // raw fallback for a nil grade column
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

    // MARK: - price_delta

    /// Fixture predates price_delta — add the table to a temp copy the way publish-tiers ships it.
    private func makeStoreWithDeltas() throws -> CatalogStore {
        let path = try FixtureCatalog.copyToTemp()
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE price_delta(card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                  pct_1d REAL, pct_7d REAL, pct_30d REAL, PRIMARY KEY(card_id, kind, key))
                """)
            try db.execute(sql: "INSERT INTO price_delta VALUES ('sv1-25', 'raw', '', 0.10, NULL, -0.05)")
            try db.execute(sql: "INSERT INTO price_delta VALUES ('sv1-25', 'psa', '10', NULL, 0.02, NULL)")
            try db.execute(sql: "INSERT INTO price_delta VALUES ('sv1-1', 'printing', 'Holofoil', 0.30, NULL, NULL)")
        }
        try dbQueue.close()
        return try CatalogStore(path: path)
    }

    func testDeltasSingleCard() throws {
        let store = try makeStoreWithDeltas()
        let records = try store.deltas(cardId: "sv1-25")
        XCTAssertEqual(records.count, 2)
        let raw = records.first { $0.kind == .raw }
        XCTAssertEqual(raw?.key, "")
        XCTAssertEqual(raw?.pct1d, 0.10)
        XCTAssertNil(raw?.pct7d)
        XCTAssertEqual(raw?.pct30d, -0.05)
        XCTAssertEqual(raw?.pct(for: .d1), 0.10)
        XCTAssertNil(raw?.pct(for: .d7))
        let psa = records.first { $0.kind == .psa }
        XCTAssertEqual(psa?.key, "10")
        XCTAssertEqual(psa?.pct(for: .d7), 0.02)
    }

    func testDeltasBatch() throws {
        let store = try makeStoreWithDeltas()
        let byCard = try store.deltas(cardIds: ["sv1-25", "sv1-1", "missing"])
        XCTAssertEqual(byCard["sv1-25"]?.count, 2)
        XCTAssertEqual(byCard["sv1-1"]?.first?.kind, .printing)
        XCTAssertEqual(byCard["sv1-1"]?.first?.key, "Holofoil")
        XCTAssertNil(byCard["missing"])
        XCTAssertEqual(try store.deltas(cardIds: []), [:])
    }

    func testDeltasThrowsWithoutTable() throws {
        let store = try FixtureCatalog.make()   // fixture has no price_delta table
        XCTAssertThrowsError(try store.deltas(cardId: "sv1-25"))
        XCTAssertThrowsError(try store.deltas(cardIds: ["sv1-25"]))
    }

    func testDeltaPeriodCycle() {
        XCTAssertEqual(DeltaPeriod.d1.next, .d7)
        XCTAssertEqual(DeltaPeriod.d7.next, .d30)
        XCTAssertEqual(DeltaPeriod.d30.next, .d1)
        XCTAssertEqual(DeltaPeriod.d7.label, "last week")
    }

    // MARK: - Expert-tier chart overlay history

    /// Fixture predates the expert history tables — create them on a temp copy with rows in the
    /// REAL production formats: graded_history.grade is PPT's key verbatim ("psa10", lowercase),
    /// and price_history_cond.condition can carry printing names alongside real conditions.
    private func makeStoreWithOverlayHistory() throws -> CatalogStore {
        let path = try FixtureCatalog.copyToTemp()
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS graded_history(card_id TEXT NOT NULL, grade TEXT NOT NULL, date TEXT NOT NULL,
                  usd REAL NOT NULL, PRIMARY KEY(card_id, grade, date))
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS price_history_cond(card_id TEXT NOT NULL, condition TEXT NOT NULL, date TEXT NOT NULL,
                  raw_usd REAL NOT NULL, PRIMARY KEY(card_id, condition, date))
                """)
            try db.execute(sql: "INSERT INTO graded_history VALUES ('sv1-25', 'psa10', '2026-07-01', 90.0)")
            try db.execute(sql: "INSERT INTO graded_history VALUES ('sv1-25', 'psa10', '2026-07-08', 95.0)")
            try db.execute(sql: "INSERT INTO graded_history VALUES ('sv1-25', 'psa9', '2026-07-01', 60.0)")
            try db.execute(sql: "INSERT INTO price_history_cond VALUES ('sv1-25', 'Damaged', '2026-07-01', 1.5)")
            try db.execute(sql: "INSERT INTO price_history_cond VALUES ('sv1-25', 'Near Mint', '2026-07-01', 4.0)")
            // Real catalogs carry printing names in the condition column (PPT source quirk) — ignored.
            try db.execute(sql: "INSERT INTO price_history_cond VALUES ('sv1-25', 'Holofoil', '2026-07-01', 9.0)")
        }
        try dbQueue.close()
        return try CatalogStore(path: path)
    }

    func testGradedHistoryMatchesPptKeyFormat() throws {
        let store = try makeStoreWithOverlayHistory()
        XCTAssertEqual(try store.gradedHistory(cardId: "sv1-25", grade: "10").map(\.value), [90.0, 95.0])
        XCTAssertEqual(try store.gradedHistory(cardId: "sv1-25", grade: "9").map(\.value), [60.0])
        XCTAssertTrue(try store.gradedHistory(cardId: "sv1-25", grade: "8").isEmpty)
    }

    func testAvailableOverlayDimensions() throws {
        let store = try makeStoreWithOverlayHistory()
        XCTAssertEqual(try store.availableGrades(cardId: "sv1-25"), [.psa10, .psa9])          // highest first
        XCTAssertEqual(try store.availableConditions(cardId: "sv1-25"), [.nearMint, .damaged]) // NM→DMG, junk dropped
        XCTAssertEqual(try store.availableGrades(cardId: "sv1-1"), [])
        XCTAssertEqual(try store.availableConditions(cardId: "sv1-1"), [])
    }

    // MARK: - price_matrix / graded_by_printing

    /// Fixture predates price_matrix/graded_by_printing and the price_delta 'matrix' kind — add
    /// them to a temp copy the way publish-tiers ships them.
    private func makeStoreWithMatrixTables() throws -> CatalogStore {
        let path = try FixtureCatalog.copyToTemp()
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE price_matrix(card_id TEXT NOT NULL, printing TEXT NOT NULL, condition TEXT NOT NULL,
                  usd REAL NOT NULL, as_of TEXT NOT NULL, PRIMARY KEY(card_id, printing, condition))
                """)
            try db.execute(sql: """
                CREATE TABLE graded_by_printing(card_id TEXT NOT NULL, printing TEXT NOT NULL, grade TEXT NOT NULL,
                  usd REAL NOT NULL, as_of TEXT NOT NULL, PRIMARY KEY(card_id, printing, grade))
                """)
            try db.execute(sql: """
                CREATE TABLE price_delta(card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                  pct_1d REAL, pct_7d REAL, pct_30d REAL, PRIMARY KEY(card_id, kind, key))
                """)
            try db.execute(sql: "INSERT INTO price_matrix VALUES ('swsh7-215', 'Holofoil', 'Near Mint', 100, '2026-07-04')")
            try db.execute(sql: "INSERT INTO price_matrix VALUES ('swsh7-215', 'Holofoil', 'Lightly Played', 80, '2026-07-04')")
            try db.execute(sql: "INSERT INTO price_matrix VALUES ('swsh7-215', 'Reverse Holofoil', 'Near Mint', 120, '2026-07-04')")
            try db.execute(sql: "INSERT INTO graded_by_printing VALUES ('base1-4', '1st Edition', 'psa10', 5000, '2026-07-04')")
            try db.execute(sql: "INSERT INTO graded_by_printing VALUES ('base1-4', 'Unlimited', 'psa10', 900, '2026-07-04')")
            try db.execute(sql: "INSERT INTO price_delta VALUES ('swsh7-215', 'matrix', 'Holofoil|Near Mint', 0.1, NULL, NULL)")
        }
        try dbQueue.close()
        return try CatalogStore(path: path)
    }

    func testMatrixPrices() throws {
        let store = try makeStoreWithMatrixTables()
        let m = try store.matrixPrices(cardId: "swsh7-215")
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.first { $0.printing == "Holofoil" && $0.condition == .lightlyPlayed }?.usd, 80)
    }

    func testMatrixPricesMissingTableIsEmptyViaTry() throws {
        // `oldStore` is a store over the base fixture, which lacks price_matrix (old artifact):
        // (try? …) ?? [] must yield [].
        let oldStore = try FixtureCatalog.make()
        XCTAssertEqual((try? oldStore.matrixPrices(cardId: "swsh7-215")) ?? [], [])
    }

    func testGradedPrintingPrices() throws {
        let store = try makeStoreWithMatrixTables()
        let g = try store.gradedPrintingPrices(cardId: "base1-4")
        XCTAssertEqual(g.first { $0.printing == "1st Edition" }?.usd, 5000)
    }

    func testMatrixDeltaKindParses() throws {
        let store = try makeStoreWithMatrixTables()
        let d = try store.deltas(cardId: "swsh7-215")
        XCTAssertEqual(d.first { $0.kind == .matrix }?.key, "Holofoil|Near Mint")
    }

    // MARK: - graded_sales / liquidity

    /// graded_sales added to a temp copy the way publish-tiers ships it (all tiers), plus the
    /// price_latest sellers/listings columns.
    private func makeStoreWithGradedSales() throws -> CatalogStore {
        let path = try FixtureCatalog.copyToTemp()
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE graded_sales(card_id TEXT NOT NULL, grade TEXT NOT NULL,
                  sales_count INTEGER NOT NULL, confidence TEXT, as_of TEXT NOT NULL,
                  PRIMARY KEY(card_id, grade));
                """)
            try db.execute(sql: "INSERT INTO graded_sales VALUES ('swsh7-215','psa10',14,'high','2026-07-19')")
            try db.execute(sql: "INSERT INTO graded_sales VALUES ('swsh7-215','cgc9',2,NULL,'2026-07-19')")
            try db.execute(sql: "ALTER TABLE price_latest ADD COLUMN sellers INTEGER")
            try db.execute(sql: "ALTER TABLE price_latest ADD COLUMN listings INTEGER")
            try db.execute(sql: "UPDATE price_latest SET sellers = 23, listings = 61 WHERE card_id = 'swsh7-215'")
        }
        try dbQueue.close()
        return try CatalogStore(path: path)
    }

    func testGradedSales() throws {
        let store = try makeStoreWithGradedSales()
        let sales = try store.gradedSales(cardId: "swsh7-215")
        XCTAssertEqual(sales.count, 2)
        XCTAssertEqual(sales.first { $0.grade == "psa10" }?.salesCount, 14)
        XCTAssertEqual(sales.first { $0.grade == "psa10" }?.confidence, "high")
        XCTAssertNil(sales.first { $0.grade == "cgc9" }?.confidence)
    }

    func testGradedSalesMissingTableIsEmptyViaTry() throws {
        let store = try FixtureCatalog.make()  // fixture predates graded_sales
        XCTAssertEqual((try? store.gradedSales(cardId: "swsh7-215")) ?? [], [])
    }

    func testPriceRecordLiquidity() throws {
        let store = try makeStoreWithGradedSales()
        let p = try store.price(cardId: "swsh7-215")
        XCTAssertEqual(p?.sellers, 23)
        XCTAssertEqual(p?.listings, 61)
    }

    func testPriceRecordLiquidityMissingColumnsReadAsNil() throws {
        let store = try FixtureCatalog.make()  // fixture predates the columns
        let p = try store.price(cardId: "swsh7-215")
        XCTAssertNil(p?.sellers)
        XCTAssertNil(p?.listings)
    }
}
