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
        let persisted = await eventually { repo.stored.keys.contains("c1") }
        XCTAssertTrue(persisted, "toggle must reach the repo")
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
        let persisted = await eventually { repo.stored["c1"]?.targetUsd == 25 }
        XCTAssertTrue(persisted, "the edit must reach the repo, got \(String(describing: repo.stored["c1"]?.targetUsd))")
    }

    /// Regression guard for a lost update. `persist` saves the WHOLE map, so back-to-back edits
    /// race: unstructured `Task`s carry no ordering guarantee, and when the older snapshot landed
    /// last it silently discarded the newer edit. In the app that's hearting a card, immediately
    /// setting a target, and watching the target vanish. Surfaced as an intermittent failure in
    /// `testUpdateMutatesEntryAndIsNoOpWhenNotWanted`; this asserts the ordering directly.
    func testRapidEditsPersistInOrderAndKeepTheLastWrite() async throws {
        let repo = InMemoryWantsRepository()
        let model = WantsModel(repo: repo, uid: "u1")

        model.toggle("c1")
        for target in 1...12 { model.update("c1") { $0.targetUsd = Double(target) } }

        let settled = await eventually { repo.stored["c1"]?.targetUsd == 12 }
        XCTAssertTrue(settled,
                      "the newest edit must win; got \(String(describing: repo.stored["c1"]?.targetUsd))")
        XCTAssertEqual(model.entry("c1")?.targetUsd, 12)
    }

    /// `WantsModel.persist` writes through an unstructured `Task`, so the repo lands on its own
    /// schedule. These tests used to sleep a fixed 20 ms and assert — which loses the race under
    /// load and made the suite intermittently red (one failure per few full runs, previously
    /// written off as a harness flake). Poll for the expected state instead: fast when the write
    /// is quick, tolerant when the machine is busy, and it still fails in bounded time if the
    /// write never happens.
    private func eventually(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}
