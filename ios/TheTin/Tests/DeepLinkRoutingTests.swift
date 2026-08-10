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

    /// The app listens on two doors now — `onOpenURL` and `onContinueUserActivity` — because a
    /// universal link doesn't reliably arrive at the first, and on a cold launch never does.
    /// Both can fire for one tap, and a double bump would push the card twice.
    func testTheSameLinkDeliveredTwiceRoutesOnce() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.cardRouteToken
        let url = URL(string: "https://thetinapp.com/c/base1-4?v=1&p=holo&c=NM")!
        model.handleDeepLink(url)
        model.handleDeepLink(url)
        XCTAssertEqual(model.cardRouteToken, before + 1, "one tap is one navigation")
        XCTAssertEqual(model.pendingCardId, "base1-4")
    }

    /// Collapsing duplicates must not break opening two different cards in quick succession —
    /// scanning a stack of labels is exactly that.
    func testTwoDIFFERENTLinksBothRoute() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.cardRouteToken
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/base1-4")!)
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/neo1-5")!)
        XCTAssertEqual(model.cardRouteToken, before + 2)
        XCTAssertEqual(model.pendingCardId, "neo1-5")
    }

    func testNonCardLinkIgnored() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.cardRouteToken
        model.handleDeepLink(URL(string: "https://thetinapp.com/privacy/")!)
        XCTAssertEqual(model.cardRouteToken, before)
        XCTAssertNil(model.pendingCardId)
    }
}
