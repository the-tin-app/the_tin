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
}
