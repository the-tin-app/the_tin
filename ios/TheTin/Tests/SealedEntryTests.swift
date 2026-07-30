import XCTest
@testable import TheTin

@MainActor
final class SealedEntryTests: XCTestCase {
    private func tempPaths() throws -> CollectionPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return CollectionPaths(fileURL: dir.appendingPathComponent("collection.json"))
    }

    private func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    func testRoundTripsThroughJSON() throws {
        let entry = SealedEntry(id: "s1", productId: 517_898, qty: 2, pricePaid: 289.99,
                                acquiredAt: Date(timeIntervalSince1970: 1_700_000_000),
                                acquiredFrom: "Card shop", acquiredVia: AcquiredVia.bought.rawValue,
                                addedAt: Date(timeIntervalSince1970: 1_700_086_400),
                                soldAt: Date(timeIntervalSince1970: 1_800_000_000), soldFor: 340)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SealedEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.acquiredViaValue, .bought)
    }

    /// The acquisition block is entirely optional — a box you just own, with nothing recorded
    /// about how it arrived, is the common case and must survive a round trip as all-nil.
    func testDecodesWithOnlyTheRequiredFields() throws {
        let json = #"{"id":"s1","productId":517898,"qty":1,"addedAt":0}"#
        let decoded = try JSONDecoder().decode(SealedEntry.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "s1")
        XCTAssertEqual(decoded.productId, 517_898)
        XCTAssertEqual(decoded.qty, 1)
        XCTAssertNil(decoded.pricePaid)
        XCTAssertNil(decoded.acquiredAt)
        XCTAssertNil(decoded.acquiredFrom)
        XCTAssertNil(decoded.acquiredVia)
        XCTAssertNil(decoded.soldAt)
        XCTAssertNil(decoded.soldFor)
    }

    func testIsSoldReflectsSoldAt() throws {
        var entry = SealedEntry(id: "s1", productId: 1, qty: 1, addedAt: Date())
        XCTAssertFalse(entry.isSold)
        entry.soldAt = Date()
        XCTAssertTrue(entry.isSold)
    }

    // MARK: Portfolio arithmetic
    //
    // These pin the contract that the portfolio headline and the tin's Sealed section both read:
    // market × qty, sold excluded, unpriced contributing nothing.

    private func product(_ id: Int, market: Double?) -> SealedProduct {
        SealedProduct(tcgplayerId: id, name: "Product \(id)", setId: "s1",
                      productType: "Booster Box", marketUsd: market, lowUsd: nil,
                      asOf: "2026-07-28")
    }

    func testMarketValueMultipliesByQuantity() {
        let sealed = [SealedEntry(id: "s1", productId: 1, qty: 3, addedAt: Date())]
        let value = sealed.marketValue(products: [1: product(1, market: 119.99)])

        XCTAssertEqual(value.total, 359.97, accuracy: 0.001)
        XCTAssertEqual(value.boxes, 3)
        XCTAssertEqual(value.priced, 3)
    }

    /// A sold box keeps its cost basis on file but stops counting toward what you own — the same
    /// rule `CollectionEntry.isSold` earns, and for the same reason: without it, selling at a loss
    /// improves the numbers by removing itself from them.
    func testMarketValueExcludesSoldBoxes() {
        let sealed = [
            SealedEntry(id: "kept", productId: 1, qty: 1, addedAt: Date()),
            SealedEntry(id: "gone", productId: 1, qty: 5, pricePaid: 400, addedAt: Date(),
                        soldAt: Date(), soldFor: 600),
        ]
        let value = sealed.marketValue(products: [1: product(1, market: 100)])

        XCTAssertEqual(value.total, 100)
        XCTAssertEqual(value.boxes, 1)
        XCTAssertEqual(sealed.boxCount, 1)
        // The sold row is still on file with its cost basis intact — excluded from the total,
        // not deleted.
        XCTAssertEqual(sealed.first { $0.id == "gone" }?.pricePaid, 400)
    }

    /// The browse tile's badge: boxes of ONE product, summed across rows and sold ones excluded.
    /// Adding the same box twice makes two entries, so reading the count off a single row would
    /// make the set screen contradict the tin.
    func testBoxCountForOneProductSumsRowsAndExcludesSold() {
        let sealed = [
            SealedEntry(id: "a", productId: 7, qty: 2, addedAt: Date()),
            SealedEntry(id: "b", productId: 7, qty: 1, addedAt: Date()),
            SealedEntry(id: "sold", productId: 7, qty: 4, addedAt: Date(), soldAt: Date()),
            SealedEntry(id: "other", productId: 8, qty: 9, addedAt: Date()),
        ]

        XCTAssertEqual(sealed.boxCount(productId: 7), 3)
        XCTAssertEqual(sealed.boxCount(productId: 8), 9)
        // A product you've never owned reads 0, which is what hides the badge entirely.
        XCTAssertEqual(sealed.boxCount(productId: 999), 0)
    }

    /// An unpriced product contributes NOTHING rather than zero, and says so through `priced`.
    /// Treating "no data" as $0 would quietly understate a collection instead of admitting a gap.
    func testMarketValueTreatsUnpricedAsUnknownNotZero() {
        let sealed = [
            SealedEntry(id: "a", productId: 1, qty: 2, addedAt: Date()),
            SealedEntry(id: "b", productId: 2, qty: 1, addedAt: Date()),   // not in the catalog
            SealedEntry(id: "c", productId: 3, qty: 1, addedAt: Date()),   // present, no price
        ]
        let value = sealed.marketValue(products: [1: product(1, market: 50),
                                                  3: product(3, market: nil)])

        XCTAssertEqual(value.total, 100)
        XCTAssertEqual(value.priced, 2)
        XCTAssertEqual(value.boxes, 4)
    }

    /// THE regression that matters. A `collection.json` written before `sealed` existed carries
    /// no such key; if the snapshot field were a defaulted non-optional, synthesized `Decodable`
    /// would still DEMAND it and every existing collection would fail to decode — silently, into
    /// an empty tin, because the repository degrades a read failure to in-memory.
    func testCollectionFileWrittenBeforeSealedExistedStillDecodes() async throws {
        let paths = try tempPaths()
        let legacy = """
        {"groups":[{"id":"g1","name":"Binder","sortOrder":0,"createdAt":0}],\
        "entries":[{"id":"e1","cardId":"ex6-58","groupId":"g1","qty":2,"addedAt":0}]}
        """
        try Data(legacy.utf8).write(to: paths.fileURL)

        let repo = LocalCollectionRepository(paths: paths)
        let groups = await firstValue(repo.groupsStream()) ?? []
        let entries = await firstValue(repo.entriesStream()) ?? []

        XCTAssertEqual(groups.map(\.name), ["Binder"])
        XCTAssertEqual(entries.map(\.id), ["e1"])
        XCTAssertEqual(entries.first?.qty, 2)
    }
}
