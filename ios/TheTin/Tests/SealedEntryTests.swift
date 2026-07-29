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
