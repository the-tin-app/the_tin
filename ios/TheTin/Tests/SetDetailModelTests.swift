import XCTest
@testable import TheTin

@MainActor
final class SetDetailModelTests: XCTestCase {
    private var store: CatalogStore!

    override func setUpWithError() throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
    }

    override func tearDownWithError() throws { try store?.close() }

    private func makeModel() throws -> SetDetailModel {
        let set = try XCTUnwrap(store.set(id: "swsh7"))
        return SetDetailModel(store: store, set: set)
    }

    func testLoadsCardsPricesAndTotals() throws {
        let model = try makeModel()
        // "TG20" sorts first: SQLite's CAST("TG20" AS INTEGER) is 0, lowest of the group.
        XCTAssertEqual(model.cards.map(\.number), ["TG20", "12", "94", "215"])
        XCTAssertEqual(model.prices.count, 2)          // Metapod and Charizard V have no price row
        XCTAssertEqual(model.rawTotal, 122.6, accuracy: 0.001)
        XCTAssertEqual(model.asOf, "2026-07-04")
    }

    func testCompletionFromEntries() throws {
        let model = try makeModel()
        let entries = [
            CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "g", qty: 2, condition: nil,
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()),
            CollectionEntry(id: "e2", cardId: "sv1-1", groupId: "g", qty: 1, condition: nil,
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()),
        ]
        let completion = model.completion(entries: entries)
        XCTAssertEqual(completion.owned, 1)
        XCTAssertEqual(completion.total, 237)
    }

    func testCardDetailHistoryStates() async throws {
        struct FakeHistory: PriceHistoryProviding {
            var points: [PricePoint]?
            func rawHistory(cardId: String) async throws -> [PricePoint] {
                guard let points else { throw URLError(.notConnectedToInternet) }
                return points
            }
        }
        let card = try XCTUnwrap(store.card(id: "swsh7-215"))
        let points = [PricePoint(date: Date(timeIntervalSince1970: 0), value: 90),
                      PricePoint(date: Date(timeIntervalSince1970: 86_400), value: 92.5)]

        let model = CardDetailModel(store: store, card: card, history: FakeHistory(points: points))
        XCTAssertEqual(model.price?.rawUsd, 92.5)
        await model.loadHistory()
        XCTAssertEqual(model.historyState, .loaded([PriceSeries(name: "Raw", points: points)]))

        let offline = CardDetailModel(store: store, card: card, history: FakeHistory(points: nil))
        await offline.loadHistory()
        XCTAssertEqual(offline.historyState, .unavailable) // never a blank screen (spec §6)
    }
}
