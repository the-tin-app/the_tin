import XCTest
@testable import TheTin

@MainActor
final class LocalWantsRepositoryTests: XCTestCase {
    private func tempPaths() throws -> WantsPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WantsPaths(fileURL: dir.appendingPathComponent("wants.json"))
    }
    private func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    func testSaveAddsAndPersistsAcrossInstances() async throws {
        let paths = try tempPaths()
        let a = LocalWantsRepository(paths: paths)
        try await a.save(uid: "u", entries: ["ex8-63": WantEntry(priority: .high),
                                             "hgss3-39": WantEntry()])
        let b = LocalWantsRepository(paths: paths)   // fresh instance, same file
        let got = await firstValue(b.stream(uid: "x")) ?? [:]
        XCTAssertEqual(Set(got.keys), ["ex8-63", "hgss3-39"])
        XCTAssertEqual(got["ex8-63"]?.priority, .high)
    }

    func testMigratesLegacyIdArray() async throws {
        let paths = try tempPaths()
        // Legacy format: a bare JSON array of ids (what Set<String> encoded to).
        try Data("[\"a-1\",\"b-2\"]".utf8).write(to: paths.fileURL)
        let repo = LocalWantsRepository(paths: paths)
        let got = await firstValue(repo.stream(uid: "x")) ?? [:]
        XCTAssertEqual(Set(got.keys), ["a-1", "b-2"])
        XCTAssertEqual(got["a-1"]?.priority, .normal)   // migrated to defaults
        XCTAssertEqual(got["a-1"]?.notes, "")
    }

    /// A wishlist written by a NEWER build must not wipe the list on an older one.
    ///
    /// This is the whole point: an unknown priority used to fail the dictionary decode, fail the
    /// legacy array fallback too, and return `[:]` — which the next write then persisted over the
    /// file. Silent, total loss, triggered by the routine move of installing build N−1 to check a
    /// regression. Now the unknown tier reads as Normal and everything else survives.
    ///
    /// ⚠️ This case used `-1` as its unknown tier, because on `staging` that is exactly what `-1`
    /// was. On THIS branch `-1` is `.grail`, so it had to move to a value no build has claimed.
    /// That is the test working at a merge, not a test that broke: the day grail ships, `-1`
    /// stops being the hazard and whatever tier comes next becomes it.
    func testAWishlistFromANewerBuildIsNotWipedByAnUnknownPriority() async throws {
        let paths = try tempPaths()
        // `-2` is the tier some future build introduces; this one has no case for it.
        let fromTheFuture = """
        {"a-1":{"priority":-2,"notes":"the grail","addedAt":0,"targetUsd":250},
         "b-2":{"priority":0,"notes":"","addedAt":0}}
        """
        try Data(fromTheFuture.utf8).write(to: paths.fileURL)

        let repo = LocalWantsRepository(paths: paths)
        let got = await firstValue(repo.stream(uid: "x")) ?? [:]

        XCTAssertEqual(Set(got.keys), ["a-1", "b-2"], "the whole list must survive")
        XCTAssertEqual(got["a-1"]?.priority, .normal, "an unknown tier reads as Normal")
        // Only the tier LABEL is lost. Everything else on that card is still there — the
        // difference between a downgrade costing one field and costing the entire wishlist.
        XCTAssertEqual(got["a-1"]?.notes, "the grail")
        XCTAssertEqual(got["a-1"]?.targetUsd, 250)
        XCTAssertEqual(got["b-2"]?.priority, .high, "known tiers are untouched")
    }

    /// The other half of the same story: `-1` is no longer unknown here, and must decode as the
    /// real tier rather than being swallowed by the lenient path meant for future ones.
    func testGrailDecodesAsGrailAndNotAsNormal() async throws {
        let paths = try tempPaths()
        try Data(#"{"a-1":{"priority":-1,"notes":"","addedAt":0}}"#.utf8).write(to: paths.fileURL)

        let repo = LocalWantsRepository(paths: paths)
        let got = await firstValue(repo.stream(uid: "x")) ?? [:]

        XCTAssertEqual(got["a-1"]?.priority, .grail)
    }

    /// A corrupt priority is still just one bad field, not a reason to discard the list.
    func testANonNumericPriorityDoesNotDiscardTheList() async throws {
        let paths = try tempPaths()
        try Data(#"{"a-1":{"priority":"high","notes":"","addedAt":0}}"#.utf8).write(to: paths.fileURL)

        let repo = LocalWantsRepository(paths: paths)
        let got = await firstValue(repo.stream(uid: "x")) ?? [:]

        XCTAssertEqual(Set(got.keys), ["a-1"])
        XCTAssertEqual(got["a-1"]?.priority, .normal)
    }
}
