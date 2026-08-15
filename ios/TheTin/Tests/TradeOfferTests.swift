import XCTest
@testable import TheTin

final class TradeOfferBuilderTests: XCTestCase {
    private func c(_ id: String, _ v: Double) -> TradeOfferBuilder.Candidate {
        TradeOfferBuilder.Candidate(entryId: id, value: v)
    }

    /// The headline behaviour: 100/95/90% of what you're TAKING, not of what you own.
    func testOffersScaleToWhatYouAreTaking() {
        let out = TradeOfferBuilder.suggest(taking: 100, from: [c("a", 100), c("b", 95), c("c", 90)])
        XCTAssertEqual(out.map(\.percent), [100, 95, 90])
        XCTAssertEqual(out[0].entryIds, ["a"])
        XCTAssertEqual(out[1].entryIds, ["b"])
        XCTAssertEqual(out[2].entryIds, ["c"])
    }

    /// Found on the simulator, not by a test: a 90% row offered $163 against a 95% row's $118 —
    /// 130% of what was being received, under a label promising less than even. The closing move
    /// measures nearest-to-target in BOTH directions, so when the only unused cards are large it
    /// overshoots. A row that costs more than the row above it is not a cheaper option, it's a
    /// trap, and the screen exists to stop someone handing over too much.
    func testARowNeverAsksForMoreThanTheRowAboveIt() {
        // taking 125.74 — the real case, verbatim. 90%'s target of $113 is nearer to $44 + $119
        // than to $44 alone, so the unbounded builder took it.
        let out = TradeOfferBuilder.suggest(taking: 125.74,
                                            from: [c("a", 120), c("b", 118.63), c("c", 44.48)])
        XCTAssertEqual(out.map(\.percent), [100, 95])
        XCTAssertEqual(out[0].total, 120, accuracy: 0.01)
        XCTAssertEqual(out[1].total, 118.63, accuracy: 0.01)
        for s in out { XCTAssertLessThanOrEqual(s.total, 125.74) }
    }

    /// The rule is monotonic totals, not a cap — a genuinely cheaper lower row still appears.
    func testACheaperRowStillSurvives() {
        let out = TradeOfferBuilder.suggest(taking: 100,
                                            from: [c("a", 50), c("b", 45), c("c", 40), c("d", 5)])
        XCTAssertGreaterThan(out.count, 1)
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertLessThan(b.total, a.total) }
    }

    /// Largest first, so the offer reads as "my two best cards" rather than as an arbitrary
    /// basket of seven — you have to justify this pile to the person across the table.
    func testFillsLargestFirst() {
        let out = TradeOfferBuilder.suggest(taking: 100, from: [c("s", 10), c("big", 60), c("mid", 30)],
                                           percents: [100])
        XCTAssertEqual(out[0].entryIds, ["big", "mid", "s"])
        XCTAssertEqual(out[0].total, 100, accuracy: 0.001)
    }

    /// The closing move. Stopping $92 short when an unused $95 card exists is the wrong answer by
    /// any reading, so one overshoot is allowed when it lands nearer the target.
    func testTakesOneOvershootWhenItLandsNearerTheTarget() {
        // Target 100. Greedy alone picks nothing ($95 fits, actually) — use a case where it can't:
        // target 100, only a $120 card. Greedy takes nothing and stops $100 short; $120 is $20 off.
        let out = TradeOfferBuilder.suggest(taking: 100, from: [c("big", 120)], percents: [100])
        XCTAssertEqual(out[0].entryIds, ["big"])
        XCTAssertEqual(out[0].total, 120, accuracy: 0.001)
    }

    /// …but not when the overshoot is worse than falling short. A $500 card is not a sane answer
    /// to a $100 trade, and offering it would be the app arguing against its own user.
    func testRefusesAnOvershootThatIsWorseThanStoppingShort() {
        let out = TradeOfferBuilder.suggest(taking: 100, from: [c("huge", 500), c("fits", 80)],
                                           percents: [100])
        XCTAssertEqual(out[0].entryIds, ["fits"])
    }

    /// Nothing to suggest is an empty list, not three suggestions of zero cards — a "0%" row on
    /// screen reads as a broken feature.
    func testNothingToSuggest() {
        XCTAssertTrue(TradeOfferBuilder.suggest(taking: 0, from: [c("a", 10)]).isEmpty)
        XCTAssertTrue(TradeOfferBuilder.suggest(taking: 100, from: []).isEmpty)
        // Unpriced candidates carry a 0 value and cannot contribute to a target.
        XCTAssertTrue(TradeOfferBuilder.suggest(taking: 100, from: [c("a", 0)]).isEmpty)
    }

    /// A list worth less than their side reaches every target by offering everything, so 100/95/90
    /// were three rows naming one pile — three choices that aren't choices. One row, and it says
    /// what it actually comes to.
    func testAListThatCannotReachTheTargetOffersOneRow() {
        let out = TradeOfferBuilder.suggest(taking: 1_000, from: [c("a", 400), c("b", 300)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].total, 700, accuracy: 0.001)
        XCTAssertEqual(out[0].achieved, 0.7, accuracy: 0.001)
        XCTAssertNotEqual(Int((out[0].achieved * 100).rounded()), out[0].percent,
                          "the row must be able to tell the user it fell short")
    }

    /// …and distinct piles still get their own row. Deduping must not collapse real choices.
    func testDistinctOffersAreAllKept() {
        let out = TradeOfferBuilder.suggest(taking: 100, from: [c("a", 100), c("b", 95), c("c", 90)])
        XCTAssertEqual(out.count, 3)
        for s in out {
            XCTAssertEqual(Int((s.achieved * 100).rounded()), s.percent)
        }
    }

    func testNoCandidateIsUsedTwiceInOneOffer() {
        let out = TradeOfferBuilder.suggest(taking: 1_000, from: [c("a", 10), c("b", 20)],
                                           percents: [100])
        XCTAssertEqual(Set(out[0].entryIds).count, out[0].entryIds.count)
    }
}

@MainActor
final class TradeDeepLinkTests: XCTestCase {

    private func tradeLink(_ items: [ShareList.Item]) throws -> URL {
        try ShareList.link(kind: .trade, items: items).url
    }

    func testASharedTradeLinkOpensATrade() throws {
        let model = AppModel.makeDefault(skipFirebase: true)
        let url = try tradeLink([ShareList.Item(c: "swsh7-215", n: "Rayquaza VMAX", q: 2, d: "LP")])
        let before = model.tradeRouteToken

        model.handleDeepLink(url)
        XCTAssertEqual(model.tradeRouteToken, before + 1)
        let payload = try XCTUnwrap(model.pendingTradeOffer)
        XCTAssertEqual(payload.k, .trade)
        XCTAssertEqual(payload.i.first?.c, "swsh7-215")
    }

    /// A want link is what somebody is LOOKING for. Seeding it as "what they'll give you" would
    /// invert the entire screen, so it must not route here at all.
    func testAWantLinkDoesNotOpenATrade() throws {
        let model = AppModel.makeDefault(skipFirebase: true)
        let url = try ShareList.link(kind: .want, items: [ShareList.Item(c: "swsh7-215")]).url
        let before = model.tradeRouteToken

        model.handleDeepLink(url)
        XCTAssertEqual(model.tradeRouteToken, before)
        XCTAssertNil(model.pendingTradeOffer)
    }

    /// …and refusing it is NOT enough. The association file claims `/l` wholesale — it cannot see
    /// the payload — so iOS opens the app for a want link too, and a bare `return` left the user
    /// staring at whatever screen they were on. Found on device 2026-08-01. It has to be handed
    /// back to the browser explicitly.
    func testAWantLinkIsHandedBackToTheBrowser() throws {
        let model = AppModel.makeDefault(skipFirebase: true)
        let url = try ShareList.link(kind: .want, items: [ShareList.Item(c: "swsh7-215")]).url
        let before = model.externalURLToken

        model.handleDeepLink(url)
        XCTAssertEqual(model.externalURLToken, before + 1)
        XCTAssertEqual(model.pendingExternalURL, url)
    }

    /// A trade link opens in the app and must NOT also be thrown at Safari.
    func testATradeLinkIsNotHandedToTheBrowser() throws {
        let model = AppModel.makeDefault(skipFirebase: true)
        let url = try ShareList.link(kind: .trade, items: [ShareList.Item(c: "swsh7-215")]).url
        model.handleDeepLink(url)
        XCTAssertNil(model.pendingExternalURL)
    }

    func testAMalformedListLinkIsIgnoredRatherThanCrashing() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let before = model.tradeRouteToken
        model.handleDeepLink(URL(string: "https://thetinapp.com/l?d=notbase64url%21%21")!)
        model.handleDeepLink(URL(string: "https://thetinapp.com/l")!)
        XCTAssertEqual(model.tradeRouteToken, before)
        // Not sent to the browser either: a link we cannot decode would render an error page, and
        // bouncing the user out to see one is worse than doing nothing.
        XCTAssertNil(model.pendingExternalURL)
    }

    /// Card links must keep working — `/l` was added beside `/c`, not in front of it.
    func testCardLinksStillRoute() {
        let model = AppModel.makeDefault(skipFirebase: true)
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/base1-4")!)
        XCTAssertEqual(model.pendingCardId, "base1-4")
    }
}

@MainActor
final class TradeSeedingTests: XCTestCase {
    private var store: CatalogStore!
    override func setUpWithError() throws { store = try FixtureCatalog.make() }
    override func tearDownWithError() throws { try store?.close() }

    /// Their column arrives PRICED, not as a list of names: the payload carries condition and
    /// quantity per card, which is the only reason a percentage can be shown at all.
    func testSeedingCarriesConditionAndQuantity() throws {
        let s = TradeSession(store: store)
        s.seedTheirSide(from: ShareList.Payload(k: .trade, i: [
            ShareList.Item(c: "swsh7-215", q: 2, d: "LP"),
            ShareList.Item(c: "swsh7-94"),
        ]))
        XCTAssertEqual(s.theirs.lines.count, 2)
        let ray = try XCTUnwrap(s.theirs.lines.first { $0.entry.cardId == "swsh7-215" })
        XCTAssertEqual(ray.copies, 2)
        XCTAssertEqual(ray.entry.conditionValue, .lp)
        // A payload with no condition or quantity is one NM copy, not zero copies.
        let umbreon = try XCTUnwrap(s.theirs.lines.first { $0.entry.cardId == "swsh7-94" })
        XCTAssertEqual(umbreon.copies, 1)
        XCTAssertEqual(umbreon.entry.conditionValue, .nm)
        XCTAssertGreaterThan(s.theirValue.total, 0)
    }

    func testSeedingAWantPayloadDoesNothing() {
        let s = TradeSession(store: store)
        s.seedTheirSide(from: ShareList.Payload(k: .want, i: [ShareList.Item(c: "swsh7-215")]))
        XCTAssertTrue(s.theirs.lines.isEmpty)
    }

    /// Seeding is a REPLACEMENT. Re-opening the same link must not double their column.
    func testSeedingTwiceDoesNotDoubleTheirSide() {
        let s = TradeSession(store: store)
        let payload = ShareList.Payload(k: .trade, i: [ShareList.Item(c: "swsh7-215")])
        s.seedTheirSide(from: payload)
        s.seedTheirSide(from: payload)
        XCTAssertEqual(s.theirs.lines.count, 1)
    }

    /// Applying a suggestion REPLACES your side. Merging would leave a pile worth roughly double
    /// the target while still being labelled 95%.
    func testApplyingASuggestionReplacesYourSide() throws {
        let s = TradeSession(store: store)
        let owned = [
            CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM",
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                            addedAt: Date(), forTrade: true),
            CollectionEntry(id: "e2", cardId: "swsh7-94", groupId: "", qty: 1, condition: "NM",
                            grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                            addedAt: Date(), forTrade: true),
        ]
        s.offer(owned[0]); s.offer(owned[1])
        XCTAssertEqual(s.yours.lines.count, 2)

        s.apply(TradeOfferBuilder.Suggestion(percent: 100, entryIds: ["e2"], total: 30.1, achieved: 1),
                from: owned)
        XCTAssertEqual(s.yours.lines.map(\.id), ["e2"])
    }
}
