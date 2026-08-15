import XCTest
import GRDB
@testable import TheTin

final class BrowseStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "bstream-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, image_url TEXT, tcgplayer_id INTEGER, attacks TEXT);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, as_of TEXT);
            CREATE TABLE price_delta(card_id TEXT, kind TEXT, key TEXT, pct_1d REAL, pct_7d REAL, pct_30d REAL);
            INSERT INTO set_info VALUES ('sv1','Scarlet Base','2023-03-31',200,'Scarlet & Violet','sv1-1');
            INSERT INTO card VALUES ('sv1-1','sv1','1','A',60,'Grass','Common',NULL,'i',NULL,1,NULL);
            INSERT INTO card VALUES ('sv1-2','sv1','2','B',60,'Fire','Common',NULL,'i',NULL,2,NULL);
            INSERT INTO card VALUES ('sv1-3','sv1','3','C',60,'Water','Common',NULL,'i',NULL,3,NULL);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testPagesInOrderAndDedupBoundary() throws {
        let store = try makeStore()
        let stream = BrowseStream(store: store, criteria: BrowseCriteria(), ownedIds: [], pageSize: 2)
        XCTAssertEqual(stream.page(0).map(\.id), ["sv1-1", "sv1-2"])
        XCTAssertEqual(stream.page(1).map(\.id), ["sv1-3"])
        XCTAssertTrue(stream.page(2).isEmpty)
    }

    /// 40 cards is enough that a permutation is overwhelmingly unlikely to equal id order.
    private func makeWideStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "bstream-wide-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, image_url TEXT, tcgplayer_id INTEGER, attacks TEXT);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, as_of TEXT);
            CREATE TABLE price_delta(card_id TEXT, kind TEXT, key TEXT, pct_1d REAL, pct_7d REAL, pct_30d REAL);
            INSERT INTO set_info VALUES ('sv1','Scarlet Base','2023-03-31',200,'Scarlet & Violet','sv1-01');
            """)
            for i in 1...40 {
                let id = String(format: "sv1-%02d", i)
                try db.execute(sql: "INSERT INTO card VALUES (?,'sv1',?,?,60,'Grass','Common',NULL,'i',NULL,?,NULL)",
                               arguments: [id, "\(i)", "Card \(i)", i])
            }
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    /// `.relevance` used to be plain `c.id`, so every session — and every filter change, which
    /// restarts the deck — opened on the same cards. A seed permutes it while keeping paging
    /// coherent: pages must stay disjoint and cover the catalog exactly once.
    func testSeededRelevanceIsAStablePermutationNotIdOrder() throws {
        let store = try makeWideStore()
        let idOrder = try store.browse(criteria: BrowseCriteria(), ownedIds: [], offset: 0, limit: 40)
            .map(\.id)
        let seeded = BrowseStream(store: store, criteria: BrowseCriteria(), ownedIds: [],
                                  pageSize: 10, seed: 12345)

        let paged = (0..<4).flatMap { seeded.page($0).map(\.id) }
        XCTAssertEqual(Set(paged), Set(idOrder), "a permutation must lose no cards and invent none")
        XCTAssertEqual(paged.count, 40, "pages must not overlap")
        XCTAssertNotEqual(paged, idOrder, "seeded relevance should not be catalog id order")
        XCTAssertEqual(paged, (0..<4).flatMap { seeded.page($0).map(\.id) }, "same seed, same order")

        let other = BrowseStream(store: store, criteria: BrowseCriteria(), ownedIds: [],
                                 pageSize: 10, seed: 999_331)
        XCTAssertNotEqual(other.page(0).map(\.id), seeded.page(0).map(\.id),
                          "a different seed should open on different cards")
    }

    /// seed 0 is the documented escape hatch back to catalog id order.
    func testZeroSeedKeepsIdOrder() throws {
        let store = try makeWideStore()
        let zero = BrowseStream(store: store, criteria: BrowseCriteria(), ownedIds: [],
                                pageSize: 40, seed: 0)
        XCTAssertEqual(zero.page(0).map(\.id), zero.page(0).map(\.id).sorted())
    }
}
