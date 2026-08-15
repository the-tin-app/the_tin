import XCTest
@testable import TheTin

@MainActor
final class ConfirmationTests: XCTestCase {
    private func makeModel() -> AppModel { AppModel.makeDefault(skipFirebase: true) }

    func testConfirmRaisesAToastCarryingItsRoute() {
        let model = makeModel()
        XCTAssertNil(model.confirmation)
        model.confirm("On your trade list", route: .trade)
        XCTAssertEqual(model.confirmation?.message, "On your trade list")
        XCTAssertEqual(model.confirmation?.route, .trade)
    }

    /// A second confirmation replaces the first rather than queueing behind it — the older
    /// message is stale the moment a newer action happens.
    func testASecondConfirmationSupersedesTheFirst() {
        let model = makeModel()
        model.confirm("On your trade list", route: .trade)
        let first = model.confirmation?.id
        model.confirm("On your wishlist", route: .wishlist)
        XCTAssertEqual(model.confirmation?.message, "On your wishlist")
        XCTAssertNotEqual(model.confirmation?.id, first)
    }

    /// Taking the action dismisses the toast and bumps the route token, which is what
    /// `MainTabView` watches to push. Without the clear, the toast outlives its own navigation.
    func testOpeningTheRouteClearsTheToastAndBumpsTheToken() {
        let model = makeModel()
        let before = model.pinnedRouteToken
        model.confirm("On your trade list", route: .trade)
        model.openPinned(.trade)
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.pendingPinnedRoute, .trade)
        XCTAssertEqual(model.pinnedRouteToken, before + 1)
    }

    func testTheToastExpiresOnItsOwn() async throws {
        let model = makeModel()
        model.confirm("On your trade list", route: .trade)
        try await Task.sleep(for: AppModel.confirmationWindow + .milliseconds(500))
        XCTAssertNil(model.confirmation, "the toast should clear itself")
    }
}
