import XCTest
@testable import TheTin

@MainActor
final class WantsModelTests: XCTestCase {
    func testToggleAddsAndRemovesLocally() async {
        let repo = InMemoryWantsRepository()
        let model = WantsModel(repo: repo, uid: "u1")
        XCTAssertFalse(model.isWanted("c1"))
        model.toggle("c1")
        XCTAssertTrue(model.isWanted("c1"))
        model.toggle("c1")
        XCTAssertFalse(model.isWanted("c1"))
    }
    func testTogglePersistsThroughRepo() async throws {
        let repo = InMemoryWantsRepository()
        let model = WantsModel(repo: repo, uid: "u1")
        model.toggle("c1")
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(repo.stored.contains("c1"))
    }
}
