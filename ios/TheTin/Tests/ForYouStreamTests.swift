import XCTest
import GRDB
@testable import TheTin

final class ForYouStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-foryou-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            INSERT INTO set_info VALUES ('s1','Set One','2026-01-01',6,'Mega','s1-1');
            INSERT INTO card VALUES ('s1-1','s1','1','A',60,'','Rare','X','i',1);
            INSERT INTO card VALUES ('s1-2','s1','2','B',60,'','Rare','X','i',2);
            INSERT INTO card VALUES ('s1-3','s1','3','C',60,'','Rare','X','i',3);
            INSERT INTO card VALUES ('s1-4','s1','4','D',60,'','Rare','X','i',4);
            INSERT INTO card VALUES ('s1-5','s1','5','E',60,'','Rare','X','i',5);
            INSERT INTO card VALUES ('s1-6','s1','6','F',60,'','Rare','X','i',6);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    private func shelf(_ id: String, _ ids: [String]) -> Shelf {
        Shelf(id: id, kind: .band, subject: nil, detail: nil, cardIds: ids)
    }

    /// The home strip shows one card per reason before a second from any of them, so the first
    /// screen is a spread rather than a run from whichever reason happened to score highest.
    func testRoundRobinsAcrossShelves() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  shelves: [shelf("a", ["s1-1", "s1-3", "s1-5"]),
                                            shelf("b", ["s1-2", "s1-4", "s1-6"])],
                                  pageSize: 4)
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-1", "s1-2", "s1-3", "s1-4"])
    }

    func testPagingContinuesWhereItLeftOffAndIsDeterministic() throws {
        let store = try makeStore()
        let shelves = [shelf("a", ["s1-1", "s1-3", "s1-5"]), shelf("b", ["s1-2", "s1-4", "s1-6"])]
        let stream = ForYouStream(store: store, shelves: shelves, pageSize: 4)
        XCTAssertEqual(stream.page(1).map(\.id), ["s1-5", "s1-6"])
        XCTAssertEqual(stream.page(0).map(\.id),
                       ForYouStream(store: store, shelves: shelves, pageSize: 4).page(0).map(\.id))
    }

    /// `ShelfBuilder` already dedupes across shelves, but the stream must not depend on that — a
    /// caller can hand it any shelves it likes.
    func testACardOnTwoShelvesIsEmittedOnce() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  shelves: [shelf("a", ["s1-1", "s1-2"]),
                                            shelf("b", ["s1-1", "s1-3"])],
                                  pageSize: 6)
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-1", "s1-2", "s1-3"])
    }

    func testUnevenShelvesDrainWithoutGaps() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  shelves: [shelf("a", ["s1-1"]),
                                            shelf("b", ["s1-2", "s1-3", "s1-4"])],
                                  pageSize: 10)
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-1", "s1-2", "s1-3", "s1-4"])
    }

    /// Cold start renders no For You row at all rather than guessing. `popularMix` is deleted: it
    /// fell back to `topPricedCards`, which is how a brand-new user's first impression of a feature
    /// about what they would actually buy became a wall of $4,500 grails.
    func testNoShelvesYieldsNoCards() throws {
        XCTAssertTrue(ForYouStream(store: try makeStore(), shelves: [], pageSize: 4).page(0).isEmpty)
    }

    func testPastTheEndIsEmptyRatherThanWrapping() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  shelves: [shelf("a", ["s1-1", "s1-2"])], pageSize: 4)
        XCTAssertTrue(stream.page(3).isEmpty)
    }

    /// `cards(ids:)` returns rows in whatever order SQLite likes; the round-robin order is the
    /// product decision and has to survive the read.
    func testRoundRobinOrderSurvivesTheCatalogRead() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  shelves: [shelf("a", ["s1-6", "s1-4", "s1-2"])], pageSize: 3)
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-6", "s1-4", "s1-2"])
    }

    // MARK: ShelfStream

    func testShelfStreamPagesOneShelfInOrder() throws {
        let stream = ShelfStream(store: try makeStore(),
                                 shelf: shelf("a", ["s1-3", "s1-1", "s1-2"]), pageSize: 2)
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-3", "s1-1"])
        XCTAssertEqual(stream.page(1).map(\.id), ["s1-2"])
        XCTAssertTrue(stream.page(2).isEmpty)
    }
}
