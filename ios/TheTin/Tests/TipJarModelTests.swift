import XCTest
@testable import TheTin

private final class FakeTipStore: TipStore, @unchecked Sendable {
    var list: [TipOption]
    var outcome: Result<TipOutcome, Error> = .success(.thanked)
    var optionsError: Error?
    private(set) var purchased: [String] = []
    private(set) var optionCalls = 0
    init(_ list: [TipOption]) { self.list = list }
    func options() async throws -> [TipOption] {
        optionCalls += 1
        if let optionsError { throw optionsError }
        return list
    }
    func purchase(_ option: TipOption) async throws -> TipOutcome {
        purchased.append(option.id)
        return try outcome.get()
    }
}

private func opt(_ id: String, _ price: Decimal, recurring: Bool = false) -> TipOption {
    TipOption(id: id, title: id, price: "$\(price)", isRecurring: recurring, sortValue: price)
}

@MainActor
final class TipJarModelTests: XCTestCase {
    func testNoStoreIsUnavailable() async {
        let model = TipJarModel(store: nil)
        await model.load()
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertFalse(model.isAvailable)
    }

    func testLoadSortsCheapestFirst() async {
        let model = TipJarModel(store: FakeTipStore([opt("big", 10), opt("small", 3), opt("mid", 5)]))
        await model.load()
        guard case .ready(let list) = model.state else { return XCTFail("not ready") }
        XCTAssertEqual(list.map(\.id), ["small", "mid", "big"])
        XCTAssertTrue(model.isAvailable)
    }

    func testMonthlyListsAfterOneTimeEvenWhenPricesTie() async {
        let model = TipJarModel(store: FakeTipStore([opt("monthly", 3, recurring: true), opt("small", 3), opt("big", 10)]))
        await model.load()
        guard case .ready(let list) = model.state else { return XCTFail("not ready") }
        XCTAssertEqual(list.map(\.id), ["small", "big", "monthly"])
    }

    func testEmptyOfferingIsUnavailable() async {
        let model = TipJarModel(store: FakeTipStore([]))
        await model.load()
        XCTAssertEqual(model.state, .unavailable)
    }

    func testFetchFailureIsUnavailableAndRetries() async {
        let store = FakeTipStore([opt("a", 3)])
        store.optionsError = URLError(.notConnectedToInternet)
        let model = TipJarModel(store: store)
        await model.load()
        XCTAssertEqual(model.state, .unavailable)
        store.optionsError = nil
        await model.load()
        XCTAssertTrue(model.isAvailable)
    }

    func testLoadIsIdempotentOnceReady() async {
        let store = FakeTipStore([opt("a", 3)])
        let model = TipJarModel(store: store)
        await model.load()
        await model.load()
        XCTAssertEqual(store.optionCalls, 1)
    }

    func testPurchaseThanks() async {
        let store = FakeTipStore([opt("a", 3)])
        let model = TipJarModel(store: store)
        await model.load()
        await model.tip(opt("a", 3))
        XCTAssertEqual(store.purchased, ["a"])
        XCTAssertEqual(model.banner, .thanks)
        XCTAssertNil(model.purchasing)
    }

    func testCancelShowsNothing() async {
        let store = FakeTipStore([opt("a", 3)])
        store.outcome = .success(.cancelled)
        let model = TipJarModel(store: store)
        await model.load()
        await model.tip(opt("a", 3))
        XCTAssertNil(model.banner)
    }

    func testFailureShowsFailedBanner() async {
        let store = FakeTipStore([opt("a", 3)])
        store.outcome = .failure(URLError(.timedOut))
        let model = TipJarModel(store: store)
        await model.load()
        await model.tip(opt("a", 3))
        XCTAssertEqual(model.banner, .failed)
        XCTAssertNil(model.purchasing)
    }

    func testPurchaseWithoutStoreIsNoOp() async {
        let model = TipJarModel(store: nil)
        await model.tip(opt("a", 3))
        XCTAssertNil(model.banner)
    }
}
