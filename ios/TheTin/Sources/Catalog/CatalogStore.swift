import Foundation
import GRDB

/// Read layer over the server-built catalog SQLite (frozen Plan 1 schema).
/// The artifact ships in WAL mode, so it must live in a writable directory.
final class CatalogStore {
    private let path: String
    private let lock = NSLock()
    // DatabasePool, not DatabaseQueue: the artifact is WAL, so a pool lets main-thread reads (a set
    // tap's synchronous SetDetailModel.init reads, list bodies) run CONCURRENTLY with a detached
    // DiscoverModel.assemble read or a background price-delta write, instead of serializing behind
    // them. A serial DatabaseQueue on a WAL file made a long background query block the main thread
    // → multi-second UI freeze on tapping a set (fix 2026-07-21). Readers never block on the writer.
    private var queue: DatabasePool
    /// Lock-guarded: `reopen` swaps the handle on the main actor while detached readers
    /// (DiscoverModel.assemble, widget snapshots) fetch it concurrently.
    var dbQueue: DatabasePool { lock.withLock { queue } }

    init(path: String) throws {
        self.path = path
        queue = try DatabasePool(path: path)
    }

    func close() throws { try dbQueue.close() }

    /// Re-point this instance at the artifact file after an install swapped it underneath.
    /// Must be in place, same instance: views and models capture the store at creation and are
    /// never rebuilt mid-session, so a replacement instance leaves them querying a closed handle
    /// (the dead Discover tab after a daily update).
    func reopen() throws {
        let fresh = try DatabasePool(path: path)
        let stale = lock.withLock {
            let old = queue
            queue = fresh
            return old
        }
        try? stale.close() // best-effort: an in-flight read just errors out on its dying handle
    }

    func sets() throws -> [SetRecord] {
        // Only sets that actually have cards in the catalog — an empty set is a dead tile.
        // (Sets with cards but no prices yet are kept; prices backfill over the nightly sweep.)
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM set_info s
                WHERE EXISTS (SELECT 1 FROM card WHERE card.set_id = s.id)
                ORDER BY release_date DESC, id
                """).map(Self.setRecord)
        }
    }

    func set(id: String) throws -> SetRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM set_info WHERE id = ?", arguments: [id])
                .map(Self.setRecord)
        }
    }

    func cards(inSet setId: String) throws -> [CardRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM card WHERE set_id = ?
                ORDER BY CAST(number AS INTEGER), number
                """, arguments: [setId]).map(Self.cardRecord)
        }
    }

    func cards(ids: [String]) throws -> [CardRecord] {
        guard !ids.isEmpty else { return [] }
        let marks = databaseQuestionMarks(count: ids.count)
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM card WHERE id IN (\(marks))",
                             arguments: StatementArguments(ids)).map(Self.cardRecord)
        }
    }

    func card(id: String) throws -> CardRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [id])
                .map(Self.cardRecord)
        }
    }

    /// Card owning a TCGplayer product id (used by CSV import matching). NULL ids never match.
    func card(tcgplayerId: Int) throws -> CardRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM card WHERE tcgplayer_id = ?",
                             arguments: [tcgplayerId])
                .map(Self.cardRecord)
        }
    }

    /// tcgplayer_id → card id, every card that has one. CSV import matching (CardMatcher) reads
    /// this once instead of running `card(tcgplayerId:)` per row — that query is an unindexed
    /// scan, O(rows × cards) at the 20k-row cap.
    func tcgplayerIdMap() throws -> [Int: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, tcgplayer_id FROM card WHERE tcgplayer_id IS NOT NULL")
            // firstValueWins: tcgplayer_id isn't declared UNIQUE, so guard against a crash if two
            // cards ever share one (shouldn't happen, but a lookup map must never fatal-error).
            return rows.reduce(into: [Int: String]()) { map, row in
                let tid: Int = row["tcgplayer_id"]
                if map[tid] == nil { map[tid] = row["id"] }
            }
        }
    }

    func price(cardId: String) throws -> PriceRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM price_latest WHERE card_id = ?", arguments: [cardId])
                .map(Self.priceRecord)
        }
    }

    /// Sealed products for a set, alphabetical. Throws (→ `[]` via `try?` at call sites) on a
    /// catalog built before the `sealed_product` table existed.
    func sealedProducts(setId: String) throws -> [SealedProduct] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sealed_product WHERE set_id = ? ORDER BY name",
                             arguments: [setId]).map(Self.sealedProduct)
        }
    }

    /// Every sealed product, alphabetical. Same table-missing caveat as `sealedProducts(setId:)`.
    func allSealedProducts() throws -> [SealedProduct] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sealed_product ORDER BY name").map(Self.sealedProduct)
        }
    }

    /// Graded population for a card, one grader (default PSA), highest grade first. Throws
    /// (→ `[]` via `try?`) on a catalog with no `population` table or no rows.
    func population(cardId: String, grader: String = "PSA") throws -> [PopulationRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM population WHERE card_id = ? AND grader = ?
                ORDER BY CAST(REPLACE(grade, 'g', '') AS REAL) DESC
                """, arguments: [cardId, grader]).map(Self.populationRow)
        }
    }

    /// Graded population grouped by grading company. PSA is pinned first (it's the price-backed
    /// grader and what most collectors reach for); the rest follow by total population desc.
    /// Zero-count grades are dropped so a company's half-grade and specialty rows it never
    /// actually graded don't render as a wall of empty bars. Highest grade first within a company.
    /// Throws (→ `[]` via `try?`) on a catalog with no `population` table.
    func populationByGrader(cardId: String) throws -> [GraderPopulation] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM population WHERE card_id = ? AND count > 0
                ORDER BY CAST(REPLACE(grade, 'g', '') AS REAL) DESC
                """, arguments: [cardId]).map(Self.populationRow)
        }
        let byGrader = Dictionary(grouping: rows, by: \.grader)  // preserves grade-desc order per key
        return byGrader.keys.sorted { a, b in
            if a == "PSA" || b == "PSA" { return a == "PSA" }
            return (byGrader[a]?.first?.totalPopulation ?? 0) > (byGrader[b]?.first?.totalPopulation ?? 0)
        }.map { GraderPopulation(grader: $0, rows: byGrader[$0] ?? []) }
    }

    private static func populationRow(_ row: Row) -> PopulationRow {
        PopulationRow(grader: row["grader"], grade: row["grade"], count: row["count"] ?? 0,
                      gemRate: row["gem_rate"], totalPopulation: row["total_population"])
    }

    private static func sealedProduct(_ row: Row) -> SealedProduct {
        SealedProduct(tcgplayerId: row["tcgplayer_id"], name: row["name"], setId: row["set_id"],
                      productType: row["product_type"], marketUsd: row["market_usd"],
                      lowUsd: row["low_usd"], asOf: row["as_of"])
    }

    /// Ungraded per-condition market prices for a card, returned in canonical NM→DMG order.
    /// Empty when the card has no `price_by_condition` rows (only ~20k cards are covered).
    func conditionPrices(cardId: String) throws -> [ConditionPrice] {
        let byCond: [Condition: (Double, Int?)] = try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM price_by_condition WHERE card_id = ?",
                                        arguments: [cardId])
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Condition, (Double, Int?))? in
                guard let c = Condition(rawValue: row["condition"]) else { return nil }
                let usd: Double = row["usd"]
                return (c, (usd, row["sales_count"]))
            })
        }
        return Condition.allCases.compactMap { c in
            byCond[c].map { ConditionPrice(condition: c, usd: $0.0, salesCount: $0.1) }
        }
    }

    /// Batch of `conditionPrices(cardId:)` keyed by card id, canonical NM→DMG order. Throws on a
    /// catalog with no `price_by_condition` table (→ `[:]` via `try?`).
    func conditionPrices(cardIds: [String]) throws -> [String: [ConditionPrice]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM price_by_condition WHERE card_id IN (\(marks))",
                             arguments: StatementArguments(cardIds))
        }
        var byCard: [String: [Condition: (Double, Int?)]] = [:]
        for r in rows {
            guard let c = Condition(rawValue: r["condition"]) else { continue }
            byCard[r["card_id"], default: [:]][c] = (r["usd"], r["sales_count"])
        }
        return byCard.mapValues { byCond in
            Condition.allCases.compactMap { c in byCond[c].map { ConditionPrice(condition: c, usd: $0.0, salesCount: $0.1) } }
        }
    }

    /// Market price per printing/finish for a card, cheapest first (from `price_by_variant`).
    /// Empty when the card has ≤1 priced printing or the catalog predates the table (`try?` → `[]`).
    func variantPrices(cardId: String) throws -> [VariantPrice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT printing, usd FROM price_by_variant WHERE card_id = ? ORDER BY usd, printing",
                             arguments: [cardId])
                .map { VariantPrice(printing: $0["printing"], usd: $0["usd"]) }
        }
    }

    /// Batch of `variantPrices(cardId:)` keyed by card id, cheapest printing first. Throws on a
    /// catalog with no `price_by_variant` table (→ `[:]` via `try?`).
    func variantPrices(cardIds: [String]) throws -> [String: [VariantPrice]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT card_id, printing, usd FROM price_by_variant WHERE card_id IN (\(marks)) ORDER BY usd, printing",
                             arguments: StatementArguments(cardIds))
        }
        var out: [String: [VariantPrice]] = [:]
        for r in rows { out[r["card_id"], default: []].append(VariantPrice(printing: r["printing"], usd: r["usd"])) }
        return out
    }

    /// Full printing×condition latest prices (`price_matrix`). Empty when the card is uncovered
    /// or the catalog predates the table (`try?` → `[]`).
    func matrixPrices(cardId: String) throws -> [MatrixPrice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT printing, condition, usd FROM price_matrix WHERE card_id = ? ORDER BY printing, condition",
                             arguments: [cardId])
                .compactMap { r in
                    Condition(rawValue: r["condition"]).map { MatrixPrice(printing: r["printing"], condition: $0, usd: r["usd"]) }
                }
        }
    }

    /// Batch of `matrixPrices(cardId:)` keyed by card id. Throws on a catalog without the
    /// table (→ `[:]` via `try?`).
    func matrixPrices(cardIds: [String]) throws -> [String: [MatrixPrice]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT card_id, printing, condition, usd FROM price_matrix WHERE card_id IN (\(marks)) ORDER BY printing, condition",
                             arguments: StatementArguments(cardIds))
        }
        var out: [String: [MatrixPrice]] = [:]
        for r in rows {
            guard let c = Condition(rawValue: r["condition"]) else { continue }
            out[r["card_id"], default: []].append(MatrixPrice(printing: r["printing"], condition: c, usd: r["usd"]))
        }
        return out
    }

    /// Per-printing graded prices (`graded_by_printing`) — only distinct-product printings
    /// (e.g. 1st Edition vs Unlimited) ever have rows. Empty on old artifacts (`try?` → `[]`).
    func gradedPrintingPrices(cardId: String) throws -> [GradedPrintingPrice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT printing, grade, usd FROM graded_by_printing WHERE card_id = ?",
                             arguments: [cardId])
                .map { GradedPrintingPrice(printing: $0["printing"], grade: $0["grade"], usd: $0["usd"]) }
        }
    }

    /// eBay sales counts backing graded prices (all graders, keys verbatim). Throws (→ `[]`
    /// via `try?`) when the installed catalog predates the `graded_sales` table.
    func gradedSales(cardId: String) throws -> [GradedSale] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT grade, sales_count, confidence FROM graded_sales WHERE card_id = ?",
                             arguments: [cardId])
                .map { GradedSale(grade: $0["grade"], salesCount: $0["sales_count"] ?? 0, confidence: $0["confidence"]) }
        }
    }

    /// Batch of `gradedPrintingPrices(cardId:)` keyed by card id (→ `[:]` via `try?` on old artifacts).
    func gradedPrintingPrices(cardIds: [String]) throws -> [String: [GradedPrintingPrice]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT card_id, printing, grade, usd FROM graded_by_printing WHERE card_id IN (\(marks))",
                             arguments: StatementArguments(cardIds))
        }
        var out: [String: [GradedPrintingPrice]] = [:]
        for r in rows { out[r["card_id"], default: []].append(GradedPrintingPrice(printing: r["printing"], grade: r["grade"], usd: r["usd"])) }
        return out
    }

    func prices(cardIds: [String]) throws -> [String: PriceRecord] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM price_latest WHERE card_id IN (\(marks))",
                             arguments: StatementArguments(cardIds)).map(Self.priceRecord)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.cardId, $0) })
    }

    /// Best *ungraded* market price to preview for each card: `raw_usd` when present, else the
    /// Near-Mint (failing that, highest-value) per-condition price. Graded prices are excluded on
    /// purpose — a slab price misrepresents a raw card. Batched: one price_latest read plus one
    /// price_by_condition read for only the cards still missing a raw price.
    func previewPrices(cardIds: [String]) throws -> [String: Double] {
        guard !cardIds.isEmpty else { return [:] }
        var out = try prices(cardIds: cardIds).compactMapValues(\.rawUsd)
        let missing = cardIds.filter { out[$0] == nil }
        guard !missing.isEmpty else { return out }
        let marks = databaseQuestionMarks(count: missing.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT card_id, condition, usd FROM price_by_condition WHERE card_id IN (\(marks))",
                arguments: StatementArguments(missing))
        }
        var nm: [String: Double] = [:], best: [String: Double] = [:]
        for row in rows {
            let id: String = row["card_id"], cond: String = row["condition"]
            let usd: Double = row["usd"]
            best[id] = Swift.max(best[id] ?? usd, usd)
            if cond == Condition.nearMint.rawValue { nm[id] = usd }
        }
        for id in missing { if let v = nm[id] ?? best[id] { out[id] = v } }
        return out
    }

    /// Highest-raw-priced card (that has an image) per Pokédex id — an app-side override for the
    /// baked `rep_card_id`, which can point at an unpriced card. One grouped query; SQLite returns
    /// the `id`/`usd` from the row holding `MAX(raw_usd)`. Dexes with no priced+imaged card are
    /// simply absent (callers fall back to `rep_card_id`).
    func repByDex() throws -> [Int: (cardId: String, usd: Double)] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.dex_id AS dex, c.id AS cid, MAX(p.raw_usd) AS usd
                FROM card_dex d
                JOIN card c ON c.id = d.card_id
                JOIN price_latest p ON p.card_id = d.card_id
                WHERE c.image_base IS NOT NULL AND p.raw_usd IS NOT NULL
                GROUP BY d.dex_id
                """)
        }
        var out: [Int: (cardId: String, usd: Double)] = [:]
        for row in rows {
            let dex: Int = row["dex"], cid: String = row["cid"]
            let usd: Double = row["usd"]
            out[dex] = (cardId: cid, usd: usd)
        }
        return out
    }

    func setRawTotal(setId: String) throws -> Double {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(p.raw_usd), 0) FROM price_latest p
                JOIN card c ON c.id = p.card_id WHERE c.set_id = ?
                """, arguments: [setId]) ?? 0
        }
    }

    func priceHistory(cardId: String) throws -> [PricePoint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT date, raw_usd FROM price_history WHERE card_id = ? ORDER BY date", arguments: [cardId])
            return Self.pricePoints(rows, valueColumn: "raw_usd")
        }
    }

    /// Batch of `priceHistory(cardId:)` keyed by card id, oldest-first — one SQL `IN` query,
    /// mirroring `conditionPrices(cardIds:)`/`variantPrices(cardIds:)`. Cards with no rows are
    /// absent. Empty `price_history` table (casual tier) → `[:]`, not an error.
    func priceHistory(cardIds: [String]) throws -> [String: [PricePoint]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT card_id, date, raw_usd FROM price_history
                WHERE card_id IN (\(marks)) ORDER BY card_id, date
                """, arguments: StatementArguments(cardIds))
        }
        var byCard: [String: [Row]] = [:]
        for r in rows { byCard[r["card_id"], default: []].append(r) }
        return byCard.mapValues { Self.pricePoints($0, valueColumn: "raw_usd") }
    }

    /// Per-condition price history (`price_history_cond`) for the expert-tier chart overlay.
    /// This table is DROPPED below the expert tier, so callers MUST gate on tier == expert;
    /// querying it on a lower tier throws (missing table). Empty result is normal.
    func conditionHistory(cardId: String, condition: Condition) throws -> [PricePoint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT date, raw_usd FROM price_history_cond WHERE card_id = ? AND condition = ? ORDER BY date",
                arguments: [cardId, condition.rawValue])
            return Self.pricePoints(rows, valueColumn: "raw_usd")
        }
    }

    /// Graded (PSA) price history (`graded_history`) for one grade — expert-tier overlay.
    /// Same tier gate as `conditionHistory`. The `grade` column stores PPT's key verbatim
    /// ("psa10"); `grade` here is the bare number ("10"), matched case-insensitively.
    func gradedHistory(cardId: String, grade: String) throws -> [PricePoint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT date, usd FROM graded_history WHERE card_id = ? AND LOWER(grade) = 'psa' || ? ORDER BY date",
                arguments: [cardId, grade])
            return Self.pricePoints(rows, valueColumn: "usd")
        }
    }

    /// All price-change rows for one card (`price_delta`). Empty on the casual tier (table kept,
    /// zero rows); throws when the installed catalog predates the table — callers use `try?`.
    func deltas(cardId: String) throws -> [DeltaRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT kind, key, pct_1d, pct_7d, pct_30d FROM price_delta WHERE card_id = ?",
                arguments: [cardId]).compactMap(Self.deltaRecord)
        }
    }

    /// Batch of `deltas(cardId:)` keyed by card id — one SQL `IN` query, mirroring
    /// `conditionPrices(cardIds:)`. Cards with no rows are absent.
    func deltas(cardIds: [String]) throws -> [String: [DeltaRecord]] {
        guard !cardIds.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: cardIds.count)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT card_id, kind, key, pct_1d, pct_7d, pct_30d FROM price_delta
                WHERE card_id IN (\(marks))
                """, arguments: StatementArguments(cardIds))
        }
        var out: [String: [DeltaRecord]] = [:]
        for r in rows {
            guard let rec = Self.deltaRecord(r) else { continue }
            out[r["card_id"], default: []].append(rec)
        }
        return out
    }

    private static func deltaRecord(_ r: Row) -> DeltaRecord? {
        guard let kind = DeltaRecord.Kind(rawValue: r["kind"]) else { return nil }
        return DeltaRecord(kind: kind, key: r["key"],
                           pct1d: r["pct_1d"], pct7d: r["pct_7d"], pct30d: r["pct_30d"])
    }

    /// Conditions that actually have `price_history_cond` rows for this card, canonical NM→DMG
    /// order — drives the expert chart's condition menu (hidden when empty). Rows whose condition
    /// isn't one of the five real conditions (PPT leaks printing names into that column) drop out.
    /// Throws below the expert tier (table dropped) — callers use `try?`.
    func availableConditions(cardId: String) throws -> [Condition] {
        let names = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT condition FROM price_history_cond WHERE card_id = ?",
                                arguments: [cardId])
        }
        let present = Set(names)
        return Condition.allCases.filter { present.contains($0.rawValue) }
    }

    /// PSA grades that actually have `graded_history` rows for this card, highest grade first —
    /// drives the expert chart's grade menu (hidden when empty; production data is empty until
    /// PPT ships dated graded series — probe mode "timeseries"). Same tier gate as above.
    func availableGrades(cardId: String) throws -> [Grade] {
        let keys = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT LOWER(grade) FROM graded_history WHERE card_id = ?",
                                arguments: [cardId])
        }
        let present = Set(keys)
        return Grade.allCases.reversed().filter { present.contains($0.rawValue) }
    }

    /// Parse `(date TEXT 'yyyy-MM-dd', <valueColumn> REAL)` rows into oldest-first price points.
    private static func pricePoints(_ rows: [Row], valueColumn: String) -> [PricePoint] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
        return rows.compactMap { r in
            guard let date = fmt.date(from: r["date"]) else { return nil }
            return PricePoint(date: date, value: r[valueColumn])
        }
    }

    func priceAsOf() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT MAX(as_of) FROM price_latest")
        }
    }

    /// The printed base-count for a set (may differ from `set_info.total`, the catalog-derived
    /// count — e.g. EX-era secret rares inflate `total` past the printed denominator). Used by
    /// F1's denominator-vs-printed_total consistency check. `nil` when the set is unknown or the
    /// column is NULL (older/incomplete upstream data).
    func printedTotal(setId: String) throws -> Int? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT printed_total FROM set_info WHERE id = ?",
                                             arguments: [setId]) else { return nil }
            return row["printed_total"]
        }
    }

    /// Identical-art twin ids for a card (see `card_twin`, populated symmetrically by
    /// `build_twins.py`). Used by F1's twin-aware lock/chooser. Empty set when the card has no
    /// known twins.
    func twins(cardId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT twin_id FROM card_twin WHERE card_id = ?",
                                    arguments: [cardId]))
        }
    }

    func cardCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card") ?? 0
        }
    }

    func pokemon() throws -> [PokemonRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT dex_id, name, rep_card_id FROM pokemon ORDER BY dex_id")
                .map { PokemonRecord(dexId: $0["dex_id"], name: $0["name"], repCardId: $0["rep_card_id"]) }
        }
    }

    /// Species display names for the given dex ids (for "Because you like X" captions).
    func pokemonNames(dexIds: [Int]) throws -> [Int: String] {
        guard !dexIds.isEmpty else { return [:] }
        let placeholders = dexIds.map { _ in "?" }.joined(separator: ",")
        return try dbQueue.read { db in
            var out: [Int: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT dex_id, name FROM pokemon WHERE dex_id IN (\(placeholders))",
                                      arguments: StatementArguments(dexIds)) {
                out[r["dex_id"]] = r["name"]
            }
            return out
        }
    }

    func cards(forDex dexId: Int) throws -> [CardRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM card c JOIN card_dex d ON d.card_id = c.id
                WHERE d.dex_id = ? ORDER BY c.set_id, CAST(c.number AS INTEGER), c.number
                """, arguments: [dexId]).map(Self.cardRecord)
        }
    }

    /// card_id → dex_ids owning it (a card may map to more than one species). Used to
    /// build per-species owned counts from collection entries without a per-row join.
    func dexIds(forCards ids: [String]) throws -> [String: [Int]] {
        guard !ids.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: ids.count)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT card_id, dex_id FROM card_dex WHERE card_id IN (\(marks))",
                                        arguments: StatementArguments(ids))
            var result: [String: [Int]] = [:]
            for r in rows {
                let cardId: String = r["card_id"]
                let dexId: Int = r["dex_id"]
                result[cardId, default: []].append(dexId)
            }
            return result
        }
    }

    func cards(byArtist artist: String) throws -> [CardRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM card WHERE artist = ? ORDER BY id",
                             arguments: [artist]).map(Self.cardRecord)
        }
    }

    /// Highest-priced cards by raw USD. Cards with a null `raw_usd` are excluded (never treated as $0).
    func topPricedCards(limit: Int) throws -> [CardRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM card c JOIN price_latest p ON p.card_id = c.id
                WHERE p.raw_usd IS NOT NULL ORDER BY p.raw_usd DESC LIMIT ?
                """, arguments: [limit]).map(Self.cardRecord)
        }
    }

    /// Cards whose rarity is one of the given strings (Full-art stream). Deterministic id order;
    /// the stream shuffles/paginates on top.
    func cards(matchingRarities rarities: Set<String>) throws -> [CardRecord] {
        guard !rarities.isEmpty else { return [] }
        let placeholders = rarities.map { _ in "?" }.joined(separator: ",")
        return try dbQueue.read { db in
            try Row.fetchAll(db,
                sql: "SELECT * FROM card WHERE rarity IN (\(placeholders)) ORDER BY id",
                arguments: StatementArguments(Array(rarities))).map(Self.cardRecord)
        }
    }

    /// Highest-priced cards by raw USD, paged. Cards with null `raw_usd` are excluded.
    func topPricedCards(offset: Int, limit: Int) throws -> [CardRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM card c JOIN price_latest p ON p.card_id = c.id
                WHERE p.raw_usd IS NOT NULL ORDER BY p.raw_usd DESC, c.id LIMIT ? OFFSET ?
                """, arguments: [limit, offset]).map(Self.cardRecord)
        }
    }

    /// Distinct set eras that actually have cards, newest era first — populates the Browse filter.
    func distinctEras() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT era FROM set_info s
                WHERE era IS NOT NULL AND era <> ''
                  AND EXISTS (SELECT 1 FROM card WHERE card.set_id = s.id)
                GROUP BY era ORDER BY MAX(release_date) DESC
                """)
        }
    }

    /// Window-shopper browse: one parameterized query assembled from the non-empty `criteria`
    /// axes. Joins `set_info` only for an era filter, `price_latest` for a price band/sort
    /// (which also drops null-priced cards), `price_delta` for deals/biggest-drop. `LIMIT/OFFSET`
    /// pages in SQL; `ORDER BY … , c.id` keeps paging deterministic.
    func browse(criteria: BrowseCriteria, ownedIds: [String], offset: Int, limit: Int) throws -> [CardRecord] {
        var joins = ""
        var wheres: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []

        let needsPriceJoin = criteria.minPrice != nil || criteria.maxPrice != nil
            || criteria.sort == .priceAsc || criteria.sort == .priceDesc
        let needsDeltaJoin = criteria.dealsOnly || criteria.sort == .biggestDrop

        if !criteria.eras.isEmpty {
            joins += " JOIN set_info s ON s.id = c.set_id"
            wheres.append("s.era IN (\(databaseQuestionMarks(count: criteria.eras.count)))")
            args.append(contentsOf: criteria.eras.map { $0 })
        }
        if needsPriceJoin {
            joins += " JOIN price_latest p ON p.card_id = c.id AND p.raw_usd IS NOT NULL"
        }
        if needsDeltaJoin {
            joins += " JOIN price_delta d ON d.card_id = c.id AND d.kind = 'raw' AND d.key = ''"
        }
        if !criteria.rarities.isEmpty {
            wheres.append("c.rarity IN (\(databaseQuestionMarks(count: criteria.rarities.count)))")
            args.append(contentsOf: criteria.rarities.map { $0 })
        }
        if !criteria.types.isEmpty {
            let ors = criteria.types.map { _ in "(',' || c.types || ',') LIKE ?" }.joined(separator: " OR ")
            wheres.append("(\(ors))")
            args.append(contentsOf: criteria.types.map { "%,\($0),%" })
        }
        if !criteria.regions.isEmpty {
            let regions = PokemonRegion.all.filter { criteria.regions.contains($0.gen) }
            let ranges = regions.map { _ in "cd.dex_id BETWEEN ? AND ?" }.joined(separator: " OR ")
            wheres.append("EXISTS (SELECT 1 FROM card_dex cd WHERE cd.card_id = c.id AND (\(ranges)))")
            for r in regions { args.append(r.lo); args.append(r.hi) }
        }
        if let minP = criteria.minPrice { wheres.append("p.raw_usd >= ?"); args.append(minP) }
        if let maxP = criteria.maxPrice { wheres.append("p.raw_usd <= ?"); args.append(maxP) }
        if criteria.dealsOnly { wheres.append("d.pct_7d < ?"); args.append(DiscoverConstants.dealsMaxPct7d) }
        if criteria.sort == .biggestDrop { wheres.append("d.pct_7d IS NOT NULL") }
        if criteria.hideOwned, !ownedIds.isEmpty {
            wheres.append("c.id NOT IN (\(databaseQuestionMarks(count: ownedIds.count)))")
            args.append(contentsOf: ownedIds.map { $0 })
        }

        let orderBy: String
        switch criteria.sort {
        case .relevance:   orderBy = "c.id"
        case .priceAsc:    orderBy = "p.raw_usd ASC, c.id"
        case .priceDesc:   orderBy = "p.raw_usd DESC, c.id"
        case .biggestDrop: orderBy = "d.pct_7d ASC, c.id"
        }

        let whereSQL = wheres.isEmpty ? "" : " WHERE " + wheres.joined(separator: " AND ")
        let sql = "SELECT c.* FROM card c\(joins)\(whereSQL) ORDER BY \(orderBy) LIMIT ? OFFSET ?"
        args.append(limit); args.append(offset)

        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.cardRecord)
        }
    }

    /// Cards belonging to a curated gallery subset (Trainer/Galarian Gallery), grouped by
    /// "<setId>/<prefix>". Empty when the catalog carries no gallery-prefixed numbers.
    func galleryCards() throws -> [String: [CardRecord]] {
        let likeClauses = DiscoverConstants.galleryNumberPrefixes
            .map { _ in "number LIKE ?" }.joined(separator: " OR ")
        let args = DiscoverConstants.galleryNumberPrefixes.map { "\($0)%" }
        let cards: [CardRecord] = try dbQueue.read { db in
            try Row.fetchAll(db,
                sql: "SELECT * FROM card WHERE \(likeClauses) ORDER BY set_id, number",
                arguments: StatementArguments(args)).map(Self.cardRecord)
        }
        return Dictionary(grouping: cards) { c in
            let prefix = DiscoverConstants.galleryNumberPrefixes.first { c.number.hasPrefix($0) } ?? ""
            return "\(c.setId)/\(prefix)"
        }
    }

    /// Artists with the most cards (non-null), for auto artist-spotlight Connections.
    func topArtists(limit: Int) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT artist FROM card WHERE artist IS NOT NULL AND artist <> ''
                GROUP BY artist ORDER BY COUNT(*) DESC, artist LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The curated connected-art scenes, each with its cards in `position` order.
    func connectedArtScenes() throws -> [ConnectedArtScene] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT scene_id, title, card_id, position FROM connected_art ORDER BY scene_id, position")
            var order: [String] = []
            var titles: [String: String] = [:]
            var ids: [String: [String]] = [:]
            for r in rows {
                let sid: String = r["scene_id"]
                if ids[sid] == nil { order.append(sid); titles[sid] = r["title"] }
                ids[sid, default: []].append(r["card_id"])
            }
            return order.map { ConnectedArtScene(sceneId: $0, title: titles[$0] ?? "", cardIds: ids[$0] ?? []) }
        }
    }

    /// Curated connections (combined-art scenes and narrative arcs) from the shipped table.
    /// Falls back to kind="combined" when the column is absent (older catalog, pre-Task 11).
    func curatedConnections() throws -> [(id: String, kind: String, title: String, cardIds: [String])] {
        try dbQueue.read { db in
            let hasKind = try db.columns(in: "connected_art").contains { $0.name == "kind" }
            let kindCol = hasKind ? "kind" : "'combined' AS kind"
            let rows = try Row.fetchAll(db, sql:
                "SELECT scene_id, \(kindCol), title, card_id, position FROM connected_art ORDER BY scene_id, position")
            var order: [String] = []
            var kind: [String: String] = [:]
            var titles: [String: String] = [:]
            var ids: [String: [String]] = [:]
            for r in rows {
                let sid: String = r["scene_id"]
                if ids[sid] == nil { order.append(sid); titles[sid] = r["title"]; kind[sid] = r["kind"] }
                ids[sid, default: []].append(r["card_id"])
            }
            return order.map { (id: $0, kind: kind[$0] ?? "combined",
                                title: titles[$0] ?? "", cardIds: ids[$0] ?? []) }
        }
    }

    func setRawTotals() throws -> [String: Double] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.set_id AS sid, COALESCE(SUM(p.raw_usd), 0) AS total
                FROM card c LEFT JOIN price_latest p ON p.card_id = c.id GROUP BY c.set_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["sid"] as String, $0["total"] as Double) })
        }
    }

    // MARK: row mapping

    private static func setRecord(_ r: Row) -> SetRecord {
        SetRecord(id: r["id"], name: r["name"], releaseDate: r["release_date"],
                  total: r["total"], era: r["era"], repCardId: r["rep_card_id"])
    }

    static func cardRecord(_ r: Row) -> CardRecord {
        let types: String? = r["types"]
        // Missing column (pre-attacks catalogs) or bad JSON reads as no attacks.
        let attacksJSON: String? = r["attacks"]
        let attacks = attacksJSON.flatMap { try? JSONDecoder().decode([Attack].self, from: Data($0.utf8)) } ?? []
        return CardRecord(id: r["id"], setId: r["set_id"], number: r["number"], name: r["name"],
                          hp: r["hp"],
                          types: (types ?? "").split(separator: ",").map(String.init),
                          rarity: r["rarity"], artist: r["artist"], imageBase: r["image_base"],
                          imageUrl: r["image_url"],
                          tcgplayerId: r["tcgplayer_id"],
                          attacks: attacks)
    }

    private static func priceRecord(_ r: Row) -> PriceRecord {
        // Missing columns (pre-all-grades catalogs) read as nil — the record stays correct.
        PriceRecord(cardId: r["card_id"], rawUsd: r["raw_usd"], rawEur: r["raw_eur"],
                    psa1: r["psa1"], psa2: r["psa2"], psa3: r["psa3"], psa4: r["psa4"],
                    psa5: r["psa5"], psa6: r["psa6"], psa7: r["psa7"], psa8: r["psa8"],
                    psa9: r["psa9"], psa10: r["psa10"],
                    sellers: r["sellers"], listings: r["listings"], lowUsd: r["low_usd"], asOf: r["as_of"])
    }
}

struct PriceDelta: Codable, Equatable {
    struct Row: Codable, Equatable {
        let cardId: String
        let rawUsd: Double?
        let rawEur: Double?
        var psa1: Double? = nil
        var psa2: Double? = nil
        var psa3: Double? = nil
        var psa4: Double? = nil
        var psa5: Double? = nil
        var psa6: Double? = nil
        var psa7: Double? = nil
        var psa8: Double? = nil
        var psa9: Double? = nil
        var psa10: Double? = nil

        func value(for grade: Grade) -> Double? {
            switch grade {
            case .psa1: return psa1; case .psa2: return psa2; case .psa3: return psa3
            case .psa4: return psa4; case .psa5: return psa5; case .psa6: return psa6
            case .psa7: return psa7; case .psa8: return psa8; case .psa9: return psa9
            case .psa10: return psa10
            }
        }
    }
    let asOf: String
    let rows: [Row]
}

extension CatalogStore {
    /// Upsert daily price rows (handoff §3.1). Rows for cards not in the catalog are skipped.
    /// Writes only the psa columns the installed catalog actually has, so a new app applying a
    /// delta to a pre-all-grades catalog neither errors nor over-writes columns it doesn't know
    /// about. A true `ON CONFLICT DO UPDATE` upsert — not `INSERT OR REPLACE` — so columns this
    /// delta never names (e.g. `sellers`/`listings`) survive untouched on existing rows.
    @discardableResult
    func applyPriceDelta(_ delta: PriceDelta) throws -> Int {
        try dbQueue.write { db in
            let cols = try db.columns(in: "price_latest").map(\.name)
            let psaCols = Grade.allCases.filter { cols.contains($0.rawValue) }
            let colList = psaCols.map(\.rawValue).joined(separator: ", ")
            let placeholders = psaCols.map { _ in "?" }.joined(separator: ", ")
            let setClause = (["raw_usd", "raw_eur"] + psaCols.map(\.rawValue) + ["as_of"])
                .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
            var applied = 0
            for row in delta.rows {
                let psaValues: [DatabaseValueConvertible?] = psaCols.map { row.value(for: $0) }
                try db.execute(sql: """
                    INSERT INTO price_latest (card_id, raw_usd, raw_eur, \(colList), as_of)
                    SELECT ?, ?, ?, \(placeholders), ?
                    WHERE EXISTS (SELECT 1 FROM card WHERE id = ?)
                    ON CONFLICT(card_id) DO UPDATE SET \(setClause)
                    """, arguments: StatementArguments([row.cardId, row.rawUsd, row.rawEur] + psaValues
                                                       + [delta.asOf, row.cardId]))
                applied += db.changesCount
            }
            return applied
        }
    }
}

// GRDB's DatabasePool is internally synchronized and safe to use across threads, so the
// read-only CatalogStore can be handed to a detached feed-build task (DiscoverModel).
extension CatalogStore: @unchecked Sendable {}
