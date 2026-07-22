import XCTest
@testable import TheTin

@MainActor
final class WantsModelTests: XCTestCase {
    func testToggleAddsAndRemovesLocally() async {
        let model = WantsModel(repo: InMemoryWantsRepository(), uid: "u1")
        XCTAssertFalse(model.isWanted("c1"))
        model.toggle("c1")
        XCTAssertTrue(model.isWanted("c1"))
        XCTAssertEqual(model.wanted, ["c1"])
        model.toggle("c1")
        XCTAssertFalse(model.isWanted("c1"))
    }

    func testTogglePersistsThroughRepo() async throws {
        let repo = InMemoryWantsRepository()
        let model = WantsModel(repo: repo, uid: "u1")
        model.toggle("c1")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(repo.stored.keys.contains("c1"))
    }

    func testUpdateMutatesEntryAndIsNoOpWhenNotWanted() async throws {
        let repo = InMemoryWantsRepository()
        let model = WantsModel(repo: repo, uid: "u1")
        model.update("ghost") { $0.priority = .high }   // not wanted → no-op
        XCTAssertNil(model.entry("ghost"))
        model.toggle("c1")
        model.update("c1") { $0.priority = .high; $0.targetUsd = 25 }
        XCTAssertEqual(model.entry("c1")?.priority, .high)
        XCTAssertEqual(model.entry("c1")?.targetUsd, 25)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(repo.stored["c1"]?.targetUsd, 25)
    }
}
