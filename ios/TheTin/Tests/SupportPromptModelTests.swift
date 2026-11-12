import XCTest
@testable import TheTin

private struct StubStore: TipStore {
    var list: [TipOption] = [TipOption(id: "a", title: "A", price: "$2.99", isRecurring: false, sortValue: 2.99)]
    func options() async throws -> [TipOption] { list }
    func purchase(_ option: TipOption) async throws -> TipOutcome { .thanked }
}

@MainActor
final class SupportPromptModelTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SupportPromptModelTests-\(UUID().uuidString)")
    }

    private func make(store: TipStore? = StubStore()) -> SupportPromptModel {
        SupportPromptModel(tipJar: TipJarModel(store: store), defaults: defaults, now: { [unowned self] in clock })
    }

    func testFirstOfferShows() async {
        let p = make()
        await p.offer(.scanFiled)
        XCTAssertEqual(p.current, .scanFiled)
    }

    func testNothingToBuyNeverShows() async {
        let p = make(store: nil)
        await p.offer(.scanFiled)
        XCTAssertNil(p.current)
    }

    func testOnlyOneNoteAtATime() async {
        let p = make()
        await p.offer(.scanFiled)
        await p.offer(.myMovers)
        XCTAssertEqual(p.current, .scanFiled)
    }

    func testIgnoredNoteSilencesEveryScreenForAWeek() async {
        let p = make()
        await p.offer(.wishlistDrop)
        p.leave(.wishlistDrop)                       // walked away without touching it
        XCTAssertNil(p.current)
        clock += 6 * 86_400
        await p.offer(.myMovers)
        XCTAssertNil(p.current, "still inside the week")
        clock += 2 * 86_400
        await p.offer(.myMovers)
        XCTAssertEqual(p.current, .myMovers, "a week has passed")
    }

    func testReenteringTheSameScreenDoesNotReshow() async {
        let p = make()
        await p.offer(.portfolioValue)
        p.leave(.portfolioValue)
        await p.offer(.portfolioValue)
        XCTAssertNil(p.current)
    }

    func testDismissIsAMonth() async {
        let p = make()
        await p.offer(.scanFiled)
        p.dismiss()
        XCTAssertNil(p.current)
        clock += 8 * 86_400
        await p.offer(.scanFiled)
        XCTAssertNil(p.current, "an explicit no outlasts the weekly cooldown")
        clock += 23 * 86_400
        await p.offer(.scanFiled)
        XCTAssertEqual(p.current, .scanFiled)
    }

    func testTippingEndsPromptsForMonths() async {
        let p = make()
        await p.offer(.scanFiled)
        await p.tipJar.load()
        await p.tipJar.tip(TipOption(id: "a", title: "A", price: "$2.99", isRecurring: false, sortValue: 2.99))
        XCTAssertNil(p.current)
        clock += 60 * 86_400
        await p.offer(.scanFiled)
        XCTAssertNil(p.current)
        clock += 121 * 86_400
        await p.offer(.scanFiled)
        XCTAssertEqual(p.current, .scanFiled)
    }

    func testStateSurvivesRelaunch() async {
        let first = make()
        await first.offer(.scanFiled)
        let second = make()                          // same defaults, as after a relaunch
        await second.offer(.myMovers)
        XCTAssertNil(second.current)
    }
}
