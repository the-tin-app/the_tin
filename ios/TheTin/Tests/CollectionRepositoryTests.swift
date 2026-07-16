import XCTest
@testable import TheTin

@MainActor
final class CollectionRepositoryTests: XCTestCase {
    private var repo: InMemoryCollectionRepository!

    override func setUp() async throws { repo = InMemoryCollectionRepository() }

    private func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    func testGroupCRUD() async throws {
        let id = try await repo.createGroup(name: "Eeveelutions")
        var groups = await firstValue(repo.groupsStream()) ?? []
        XCTAssertEqual(groups.map(\.name), ["Eeveelutions"])

        try await repo.renameGroup(id: id, name: "Eevees")
        groups = await firstValue(repo.groupsStream()) ?? []
        XCTAssertEqual(groups.first?.name, "Eevees")

        try await repo.deleteGroup(id: id)
        groups = await firstValue(repo.groupsStream()) ?? []
        XCTAssertTrue(groups.isEmpty)
    }

    func testEntryCRUDAndCascadeDelete() async throws {
        let gid = try await repo.createGroup(name: "Binder")
        var entry = CollectionEntry(id: UUID().uuidString, cardId: "swsh7-215", groupId: gid, qty: 1,
                                    condition: "NM", grade: nil, pricePaid: 80, acquiredAt: nil,
                                    acquiredFrom: "card show", addedAt: Date())
        try await repo.addEntry(entry)

        entry.qty = 2
        try await repo.updateEntry(entry)
        var entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertEqual(entries.first?.qty, 2)
        XCTAssertEqual(entries.first?.cardId, "swsh7-215") // REQUIRED field always present

        try await repo.deleteGroup(id: gid) // cascades
        entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    func testStreamEmitsOnChange() async throws {
        let stream = repo.groupsStream()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial []
        _ = try await repo.createGroup(name: "New")
        let next = await iterator.next()
        XCTAssertEqual(next?.map(\.name), ["New"])
    }

    func testEntryVariantRoundTrips() async throws {
        let gid = try await repo.createGroup(name: "Binder")
        let entry = CollectionEntry(id: UUID().uuidString, cardId: "swsh7-215", groupId: gid, qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(), variant: "reverseHolo")
        try await repo.addEntry(entry)
        let entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertEqual(entries.first?.variant, "reverseHolo")
    }
}
