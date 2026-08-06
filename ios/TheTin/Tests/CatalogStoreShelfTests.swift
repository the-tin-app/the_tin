import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreShelfTests: XCTestCase {
    /// s1-1 below the band, s1-2/s1-3 inside it, s1-4 far above.
    /// s1-2 gets 10 weekly history rows and a real 7d drop; s1-3 gets 3 rows (below the floor)
    /// so "not enough history" and "no drop" are distinguishable from "the query is broken".
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-shelf-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE card_dex(card_id TEXT NOT NULL, dex_id INTEGER NOT NULL, PRIMARY KEY(card_id, dex_id));
            CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL, PRIMARY KEY(card_id, date));
            CREATE TABLE price_delta(card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                                     pct_1d REAL, pct_7d REAL, pct_30d REAL, PRIMARY KEY(card_id, kind, key));
            INSERT INTO set_info VALUES ('s1','Set One','2026-01-01',4,'Scarlet','s1-1');
            INSERT INTO set_info VALUES ('s0','Older Set','2020-01-01',1,'Sword','s0-1');
            INSERT INTO card VALUES ('s1-1','s1','1','Cheap',60,'','Common','A1','i',1);
            INSERT INTO card VALUES ('s1-2','s1','2','InBand',60,'','Rare','A2','i',2);
            INSERT INTO card VALUES ('s1-3','s1','3','AlsoInBand',60,'','Rare','A3','i',3);
            INSERT INTO card VALUES ('s1-4','s1','4','Pricey',60,'','Ultra Rare','A4','i',4);
            INSERT INTO price_latest VALUES ('s1-1',1.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01');
            INSERT INTO price_latest VALUES ('s1-2',20.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01');
            INSERT INTO price_latest VALUES ('s1-3',25.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01');
            INSERT INTO price_latest VALUES ('s1-4',900.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01');
            INSERT INTO card_dex VALUES ('s1-2',144);
            INSERT INTO card_dex VALUES ('s1-3',145);
            -- s1-2: 10 rows inside the 182-day window, lowest 20.0, so its $20 IS the low.
            INSERT INTO price_history VALUES ('s1-2',date('now','-7 day'),20.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-14 day'),22.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-21 day'),24.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-28 day'),26.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-35 day'),28.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-42 day'),30.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-49 day'),32.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-56 day'),34.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-63 day'),36.0);
            INSERT INTO price_history VALUES ('s1-2',date('now','-70 day'),38.0);
            -- s1-2 also has an ANCIENT cheaper row, outside the window: must not count as the low.
            INSERT INTO price_history VALUES ('s1-2',date('now','-400 day'),1.0);
            -- s1-3: only 3 rows, below historicLowMinRows.
            INSERT INTO price_history VALUES ('s1-3',date('now','-7 day'),25.0);
            INSERT INTO price_history VALUES ('s1-3',date('now','-14 day'),26.0);
            INSERT INTO price_history VALUES ('s1-3',date('now','-21 day'),27.0);
            INSERT INTO price_delta VALUES ('s1-2','raw','',NULL,-0.20,NULL);
            INSERT INTO price_delta VALUES ('s1-3','raw','',NULL,-0.01,NULL);
            INSERT INTO price_delta VALUES ('s1-4','psa','10',NULL,-0.90,NULL);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    private let band = PriceBand(p25: 10, p50: 20, p75: 30)

    func testCardsInPriceBandExcludesOutsideAndRespectsLimit() throws {
        let store = try makeStore()
        let ids = try store.cardsInPriceBand(band, limit: 10).map(\.id)
        XCTAssertEqual(Set(ids), ["s1-2", "s1-3"])
        XCTAssertEqual(try store.cardsInPriceBand(band, limit: 1).count, 1)
    }

    func testCardsMissingFromSetExcludesOwnedAndPrefersBand() throws {
        let store = try makeStore()
        let ids = try store.cardsMissingFromSet("s1", owned: ["s1-2"], band: band, limit: 10).map(\.id)
        XCTAssertEqual(ids, ["s1-3"])
    }

    func testCardsMissingFromSetWithoutBandReturnsWholeSet() throws {
        let store = try makeStore()
        let ids = try store.cardsMissingFromSet("s1", owned: [], band: nil, limit: 10).map(\.id)
        XCTAssertEqual(Set(ids), ["s1-1", "s1-2", "s1-3", "s1-4"])
    }

    func testCardsNearHistoricLowFindsACardSittingAtItsLow() throws {
        let store = try makeStore()
        let ids = try store.cardsNearHistoricLow(candidateIds: ["s1-2", "s1-3"],
                                                 withinPct: 0.05, limit: 10)
        XCTAssertEqual(ids, ["s1-2"])
    }

    /// s1-3 sits at its low too, but on 3 weekly rows the "low" is just the only price we ever saw.
    func testCardsNearHistoricLowIgnoresCardsWithTooLittleHistory() throws {
        let store = try makeStore()
        let ids = try store.cardsNearHistoricLow(candidateIds: ["s1-3"], withinPct: 0.05, limit: 10)
        XCTAssertTrue(ids.isEmpty)
    }

    /// ⚠️ A cheaper row from 400 days ago must not become the six-month low — otherwise every card
    /// that has ever been cheaper reads as "not near its low" forever.
    func testCardsNearHistoricLowIgnoresRowsOutsideTheWindow() throws {
        let store = try makeStore()
        // s1-2's $1.00 row is 400 days old; if it counted, $20 would be 20x the low and excluded.
        XCTAssertEqual(try store.cardsNearHistoricLow(candidateIds: ["s1-2"],
                                                      withinPct: 0.05, limit: 10), ["s1-2"])
    }

    func testCardsDroppedThisWeekFiltersKindAndThreshold() throws {
        let store = try makeStore()
        let hits = try store.cardsDroppedThisWeek(candidateIds: ["s1-2", "s1-3", "s1-4"],
                                                  maxPct: DiscoverConstants.dealsMaxPct7d, limit: 10)
        // s1-3 only fell 1% (above the -0.05 threshold); s1-4's drop is on kind='psa', not 'raw'.
        XCTAssertEqual(hits.map(\.id), ["s1-2"])
        XCTAssertEqual(hits.first?.pct ?? 0, -0.20, accuracy: 0.0001)
    }

    func testCardsForDexIdsRespectsBandAndDedupes() throws {
        let store = try makeStore()
        let ids = try store.cardsForDexIds([144, 145], band: band, limit: 10).map(\.id)
        XCTAssertEqual(Set(ids), ["s1-2", "s1-3"])
    }

    func testEmptyInputsReturnEmptyWithoutQuerying() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.cardsForDexIds([], band: band, limit: 10).isEmpty)
        XCTAssertTrue(try store.cardsNearHistoricLow(candidateIds: [], withinPct: 0.05, limit: 10).isEmpty)
        XCTAssertTrue(try store.cardsDroppedThisWeek(candidateIds: [], maxPct: -0.05, limit: 10).isEmpty)
    }

    /// ⚠️ Regression: `ORDER BY c.id LIMIT n` truncated the candidate window ALPHABETICALLY. On the
    /// real catalog that meant a 600-card window over 3,342 in-band cards stopped at `ecard2-144`,
    /// excluding every `sv*`, `swsh*`, `me*` and `xy*` card — essentially a whole modern collection.
    /// The window must be chosen by price, not by name, so it spans the catalog.
    private func makeWideStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-wide-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            """)
            // "aaa" sorts first and sits at the edge of the band; "zzz" sorts last and sits at the
            // median. Id ordering would return only aaa-*; price ordering must reach zzz-*.
            for i in 1...30 {
                try db.execute(sql: "INSERT INTO card VALUES (?,'aaa',?,?,60,'','Rare','A','i',?)",
                               arguments: ["aaa-\(i)", "\(i)", "Edge \(i)", i])
                try db.execute(sql: "INSERT INTO price_latest VALUES (?,10.5,NULL,NULL,NULL,NULL,NULL,'2026-08-01')",
                               arguments: ["aaa-\(i)"])
                try db.execute(sql: "INSERT INTO card VALUES (?,'zzz',?,?,60,'','Rare','Z','i',?)",
                               arguments: ["zzz-\(i)", "\(i)", "Typical \(i)", 1000 + i])
                try db.execute(sql: "INSERT INTO price_latest VALUES (?,20.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01')",
                               arguments: ["zzz-\(i)"])
            }
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testPriceBandWindowIsChosenByPriceNotAlphabetically() throws {
        let store = try makeWideStore()
        let ids = try store.cardsInPriceBand(band, limit: 10).map(\.id)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("zzz-") },
                      "the window must hold the cards nearest p50 ($20), not the ones named first")
    }

    func testSetGoalWindowIsChosenByPriceNotCardNumber() throws {
        let store = try makeWideStore()
        // Numbers 1...30 exist at both prices; the in-band slice must not be "the low numbers".
        let ids = try store.cardsMissingFromSet("zzz", owned: [], band: band, limit: 5).map(\.id)
        XCTAssertEqual(ids.count, 5)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("zzz-") })
    }

    func testRecentSetsAreNewestFirst() throws {
        let store = try makeStore()
        let ids = try store.recentSets(limit: 5).map(\.id)
        XCTAssertEqual(ids, ["s1", "s0"])
    }
}
