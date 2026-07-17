import XCTest
@testable import TheTin

@MainActor
final class LocalCollectionRepositoryTests: XCTestCase {
    private func tempPaths() throws -> CollectionPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return CollectionPaths(fileURL: dir.appendingPathComponent("collection.json"))
    }

    private func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    func testGroupAndEntryCRUDWithCascade() async throws {
        let repo = LocalCollectionRepository(paths: try tempPaths())
        let gid = try await repo.createGroup(name: "Binder")

        var entry = CollectionEntry(id: UUID().uuidString, cardId: "ex6-58", groupId: gid, qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(), variant: "holo")
        try await repo.addEntry(entry)
        entry.qty = 3
        try await repo.updateEntry(entry)

        var entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertEqual(entries.first?.qty, 3)
        XCTAssertEqual(entries.first?.variant, "holo")

        try await repo.deleteGroup(id: gid) // cascades
        entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    func testDeleteGroupKeepingEntriesMovesThemToNoDivider() async throws {
        let paths = try tempPaths()
        let repo = LocalCollectionRepository(paths: paths)
        let gid = try await repo.createGroup(name: "Binder")
        try await repo.addEntry(CollectionEntry(id: "e1", cardId: "ex6-58", groupId: gid, qty: 1,
                                                condition: nil, grade: nil, pricePaid: nil,
                                                acquiredAt: nil, acquiredFrom: nil,
                                                addedAt: Date(), variant: nil))

        try await repo.deleteGroup(id: gid, keepingEntries: true)
        let groups = await firstValue(repo.groupsStream()) ?? []
        XCTAssertTrue(groups.isEmpty)

        // Entry survives, ungrouped — and it persisted that way.
        let entries = await firstValue(LocalCollectionRepository(paths: paths).entriesStream()) ?? []
        XCTAssertEqual(entries.map(\.id), ["e1"])
        XCTAssertEqual(entries.first?.groupId, "")
    }

    func testReorderGroupsPersistsAndSorts() async throws {
        let paths = try tempPaths()
        let repo = LocalCollectionRepository(paths: paths)
        let a = try await repo.createGroup(name: "A")
        let b = try await repo.createGroup(name: "B")
        let c = try await repo.createGroup(name: "C")

        try await repo.reorderGroups(orderedIds: [c, a, b])
        var groups = await firstValue(repo.groupsStream()) ?? []
        XCTAssertEqual(groups.map(\.name), ["C", "A", "B"])

        // Survives a fresh instance (persisted sortOrder).
        groups = await firstValue(LocalCollectionRepository(paths: paths).groupsStream()) ?? []
        XCTAssertEqual(groups.map(\.name), ["C", "A", "B"])
    }

    func testPersistsAcrossInstances() async throws {
        let paths = try tempPaths()
        let a = LocalCollectionRepository(paths: paths)
        let gid = try await a.createGroup(name: "Trades")
        try await a.addEntry(CollectionEntry(id: "e1", cardId: "ex8-63", groupId: gid, qty: 1,
                                             condition: "LP", grade: nil, pricePaid: nil, acquiredAt: nil,
                                             acquiredFrom: nil, addedAt: Date(), variant: "reverseHolo"))
        // ungrouped ("the Tin") entry
        try await a.addEntry(CollectionEntry(id: "e2", cardId: "hgss3-39", groupId: "", qty: 1,
                                             condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                             acquiredFrom: nil, addedAt: Date(), variant: nil))

        let b = LocalCollectionRepository(paths: paths) // fresh instance, same file
        let groups = await firstValue(b.groupsStream()) ?? []
        let entries = await firstValue(b.entriesStream()) ?? []
        XCTAssertEqual(groups.map(\.name), ["Trades"])
        XCTAssertEqual(Set(entries.map(\.id)), ["e1", "e2"])
        XCTAssertEqual(entries.first(where: { $0.id == "e1" })?.variant, "reverseHolo")
        XCTAssertEqual(entries.first(where: { $0.id == "e2" })?.groupId, "")
    }

    /// A failed disk write must roll the mutation back and throw — in-memory state (and the
    /// streams) never show an entry that wouldn't survive a relaunch.
    func testFailedPersistRollsBackAndThrows() async throws {
        let paths = try tempPaths()
        let repo = LocalCollectionRepository(paths: paths)
        try await repo.addEntry(CollectionEntry(id: "kept", cardId: "ex6-58", groupId: "", qty: 1,
                                                condition: nil, grade: nil, pricePaid: nil,
                                                acquiredAt: nil, acquiredFrom: nil,
                                                addedAt: Date(), variant: nil))

        // Make the next persist fail: replace the file with a directory so the atomic write
        // can't land.
        try FileManager.default.removeItem(at: paths.fileURL)
        try FileManager.default.createDirectory(at: paths.fileURL, withIntermediateDirectories: false)

        do {
            try await repo.addEntry(CollectionEntry(id: "lost", cardId: "ex6-58", groupId: "", qty: 1,
                                                    condition: nil, grade: nil, pricePaid: nil,
                                                    acquiredAt: nil, acquiredFrom: nil,
                                                    addedAt: Date(), variant: nil))
            XCTFail("expected addEntry to throw when the disk write fails")
        } catch {}

        let entries = await firstValue(repo.entriesStream()) ?? []
        XCTAssertEqual(entries.map(\.id), ["kept"]) // rolled back, not silently kept in memory
    }

    /// Batch import must land in ONE notification carrying every entry, not N notifications
    /// (a naive per-entry loop would yield a partial [1-entry] array on this first `next()`).
    func testAddEntriesNotifiesOnce() async throws {
        let repo = LocalCollectionRepository(paths: try tempPaths())
        var iterator = repo.entriesStream().makeAsyncIterator()
        _ = await iterator.next() // initial []

        let batch = (0..<25).map { i in
            CollectionEntry(id: "e\(i)", cardId: "ex6-58", groupId: "", qty: 1, condition: nil,
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                            addedAt: Date(), variant: nil)
        }
        try await repo.addEntries(batch)

        let next = await iterator.next()
        XCTAssertEqual(next?.count, 25) // one yield containing all 25
    }
}
