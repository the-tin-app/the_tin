import XCTest
@testable import TheTin

@MainActor
final class DeepLinkRoutingTests: XCTestCase {
    func testCardLinkSetsPendingIdAndBumpsToken() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.cardRouteToken
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/base1-4")!)
        XCTAssertEqual(model.pendingCardId, "base1-4")
        XCTAssertEqual(model.cardRouteToken, before + 1)
    }

    func testCardLinkWithQueryParamsUsesPathId() {
        let model = AppModel.makeDefault(skipFirebase: true)
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/sv1-25?n=Pikachu&set=Scarlet")!)
        XCTAssertEqual(model.pendingCardId, "sv1-25")
    }

    func testNonCardLinkIgnored() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.cardRouteToken
        model.handleDeepLink(URL(string: "https://thetinapp.com/privacy/")!)
        XCTAssertEqual(model.cardRouteToken, before)
        XCTAssertNil(model.pendingCardId)
    }
}
