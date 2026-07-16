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

    func testSetWantedAddsAndRemoves() async throws {
        let repo = LocalWantsRepository(paths: try tempPaths())
        try await repo.setWanted(uid: "ignored", cardId: "ex6-58", wanted: true)
        var set = await firstValue(repo.stream(uid: "ignored")) ?? []
        XCTAssertEqual(set, ["ex6-58"])

        try await repo.setWanted(uid: "ignored", cardId: "ex6-58", wanted: false)
        set = await firstValue(repo.stream(uid: "ignored")) ?? []
        XCTAssertTrue(set.isEmpty)
    }

    func testPersistsAcrossInstancesOfflineNoAuth() async throws {
        let paths = try tempPaths()
        let a = LocalWantsRepository(paths: paths)
        // uid is ignored — wants are per-device, auth-independent.
        try await a.setWanted(uid: "u", cardId: "ex8-63", wanted: true)
        try await a.setWanted(uid: "u", cardId: "hgss3-39", wanted: true)

        let b = LocalWantsRepository(paths: paths) // fresh instance, same file
        let set = await firstValue(b.stream(uid: "different-uid")) ?? []
        XCTAssertEqual(set, ["ex8-63", "hgss3-39"])
    }
}
