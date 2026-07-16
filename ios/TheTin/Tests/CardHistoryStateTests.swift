import XCTest
import GRDB
@testable import TheTin

private struct StubHistory: PriceHistoryProviding {
    let result: Result<[PricePoint], Error>
    func rawHistory(cardId: String) async throws -> [PricePoint] { try result.get() }
}

@MainActor
final class CardHistoryStateTests: XCTestCase {
    private struct Boom: Error {}

    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            INSERT INTO card VALUES ('c1','s','1','X',NULL,'','','','img/c1',NULL);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }
    private func card(_ store: CatalogStore) throws -> CardRecord { try XCTUnwrap(store.card(id: "c1")) }

    func testEmptyHistoryIsEmptyNotUnavailable() async throws {
        let store = try makeStore()
        let model = CardDetailModel(store: store, card: try card(store), history: StubHistory(result: .success([])))
        await model.loadHistory()
        XCTAssertEqual(model.historyState, .empty)
    }

    func testThrownHistoryIsUnavailable() async throws {
        let store = try makeStore()
        let model = CardDetailModel(store: store, card: try card(store), history: StubHistory(result: .failure(Boom())))
        await model.loadHistory()
        XCTAssertEqual(model.historyState, .unavailable)
    }

    func testNonEmptyHistoryIsLoaded() async throws {
        let store = try makeStore()
        let points = [PricePoint(date: Date(timeIntervalSince1970: 0), value: 1.0)]
        let model = CardDetailModel(store: store, card: try card(store), history: StubHistory(result: .success(points)))
        await model.loadHistory()
        XCTAssertEqual(model.historyState, .loaded([PriceSeries(name: "Raw", points: points)]))
    }
}
