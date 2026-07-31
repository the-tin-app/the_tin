import XCTest
@testable import TheTin

@MainActor
final class IntentRouterTests: XCTestCase {
    /// A cold launch straight from Siri or the Action button performs the intent before any view
    /// exists. If the router dropped that request, "Hey Siri, scan a card" would open the app on
    /// whatever tab you left it on — the failure is silent and looks like the intent doing nothing.
    func testRequestArrivingBeforeInstallIsHeldAndThenDelivered() {
        let router = IntentRouter()
        var received: [AppModel.IntentRoute] = []

        router.route(.scan)
        XCTAssertTrue(received.isEmpty, "nothing to deliver to yet")

        router.install { received.append($0) }
        XCTAssertEqual(received, [.scan])
    }

    func testRequestsAfterInstallAreDeliveredImmediately() {
        let router = IntentRouter()
        var received: [AppModel.IntentRoute] = []
        router.install { received.append($0) }

        router.route(.scan)
        router.route(.search("charizard"))

        XCTAssertEqual(received, [.scan, .search("charizard")])
    }

    /// Only the last parked request survives — an intent fired twice before launch should land
    /// you where the second one asked, not replay both.
    func testOnlyTheMostRecentParkedRequestIsDelivered() {
        let router = IntentRouter()
        var received: [AppModel.IntentRoute] = []

        router.route(.scan)
        router.route(.search("pikachu"))
        router.install { received.append($0) }

        XCTAssertEqual(received, [.search("pikachu")])
    }

    /// The parked request is delivered once, not on every re-install.
    func testParkedRequestIsNotRedeliveredOnReinstall() {
        let router = IntentRouter()
        var received: [AppModel.IntentRoute] = []
        router.route(.scan)
        router.install { received.append($0) }
        router.install { received.append($0) }

        XCTAssertEqual(received, [.scan])
    }
}
