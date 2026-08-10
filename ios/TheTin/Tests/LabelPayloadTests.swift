import XCTest
@testable import TheTin

final class LabelPayloadTests: XCTestCase {

    func testRoundTripsEverythingALabelCarries() throws {
        let url = LabelPayload.url(cardId: "sv08-057", printing: .reverseHolo,
                                   condition: .lp, entryId: "550e8400-e29b")
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.cardId, "sv08-057")
        XCTAssertEqual(parsed.printing, .reverseHolo)
        XCTAssertEqual(parsed.condition, .lp)
        XCTAssertEqual(parsed.entryId, "550e8400-e29b")
    }

    /// Rule 1: the card id lives in the PATH. This is what makes every future version openable
    /// on every build ever shipped.
    func testTheCardIdIsInThePathNotTheQuery() {
        let url = LabelPayload.url(cardId: "base1-4", printing: .holo, condition: .nm,
                                   entryId: "e1")
        XCTAssertEqual(url.pathComponents, ["/", "c", "base1-4"])
        XCTAssertEqual(url.host, "thetinapp.com")
        XCTAssertEqual(url.scheme, "https")
    }

    /// Rule 2: an unknown version must still open the card, dropping what it can't read. This is
    /// the test that proves a v2 label won't brick on a v1 build.
    func testAnUnknownVersionStillYieldsTheCardAndDropsTheRest() throws {
        let url = URL(string: "https://thetinapp.com/c/base1-4?v=2&p=holo&c=NM&e=e1&zz=9")!
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.cardId, "base1-4")
        XCTAssertNil(parsed.printing, "a version we don't understand must not be interpreted")
        XCTAssertNil(parsed.condition)
        XCTAssertNil(parsed.entryId)
    }

    /// Rule 4: an unknown parameter alongside a KNOWN version is ignored, not fatal.
    func testAnUnknownParameterAtOurOwnVersionIsIgnored() throws {
        let url = URL(string: "https://thetinapp.com/c/base1-4?v=1&p=holo&c=NM&future=42")!
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.printing, .holo)
        XCTAssertEqual(parsed.condition, .nm)
        XCTAssertNil(parsed.entryId)
    }

    /// A plain share link — no `v` at all — is still a valid card open. Those exist in the wild
    /// already and must keep working.
    func testAPlainShareLinkParsesAsABareCardOpen() throws {
        let url = URL(string: "https://thetinapp.com/c/base1-4?n=Charizard&set=Base")!
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.cardId, "base1-4")
        XCTAssertNil(parsed.printing)
        XCTAssertNil(parsed.condition)
    }

    /// An unreadable CONDITION is "not recorded" — `CardCondition` is a closed enum and always
    /// will be, so a value outside it is meaningless rather than new.
    ///
    /// ⚠️ A printing is the opposite case and this test used to get it wrong. `CardVariant` stopped
    /// being an enum: an unrecognised string IS a print run ("Cosmos Holo"), which is exactly what
    /// that change was for. So `p` is preserved, never discarded — see the round-trip test below.
    func testAnUnreadableConditionIsAbsentButAPrintingIsAPrintRun() throws {
        let url = URL(string: "https://thetinapp.com/c/base1-4?v=1&p=sparkly&c=PERFECT")!
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertNil(parsed.condition, "PERFECT is not a CardCondition and never will be")
        XCTAssertEqual(parsed.printing?.rawValue, "sparkly",
                       "an unrecognised printing is a print run, not garbage")
    }

    /// A print-run copy has to get a correct label — that is the whole point of `CardVariant`
    /// being open. Dropping it would print a sticker claiming the base card, which is worse than
    /// printing nothing, because the sticker is permanent and looks authoritative.
    func testAPrintRunSurvivesTheRoundTrip() throws {
        let run = try XCTUnwrap(CardVariant(rawValue: "World Championship Decks 2004"))
        let url = LabelPayload.url(cardId: "base1-4", printing: run, condition: .nm, entryId: "e1")
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.printing, run)
        XCTAssertEqual(parsed.condition, .nm)
    }

    /// The four finishes still canonicalise, so a label written from a PPT key and one written
    /// from the rawValue are the same sticker.
    func testTheKnownFinishesStillCanonicalise() throws {
        let url = LabelPayload.url(cardId: "base1-4", printing: .reverseHolo,
                                   condition: nil, entryId: nil)
        XCTAssertEqual(try XCTUnwrap(LabelPayload.parse(url)).printing, .reverseHolo)
    }

    func testNonCardURLsAreRefused() {
        XCTAssertNil(LabelPayload.parse(URL(string: "https://thetinapp.com/privacy")!))
        XCTAssertNil(LabelPayload.parse(URL(string: "https://thetinapp.com/c/")!))
        XCTAssertNil(LabelPayload.parse(URL(string: "https://example.com/c/base1-4")!))
    }

    /// No card id in this catalog contains a slash (checked: 0 of 23,323), but ids are minted by
    /// upstream feeds and the app is meant to grow past one game — so a reserved character must
    /// survive the round trip rather than silently open a DIFFERENT card ("226/S-P" read back as
    /// "226").
    func testACardIdNeedingEscapingSurvivesTheRoundTrip() throws {
        let url = LabelPayload.url(cardId: "226/S-P", printing: nil, condition: nil, entryId: nil)
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.cardId, "226/S-P")
    }

    func testAnEntryBecomesAPayloadCarryingItsOwnPrintingAndCondition() throws {
        let entry = CollectionEntry(id: "entry-9", cardId: "base1-4", groupId: "", qty: 1,
                                    condition: "LP", grade: nil, pricePaid: nil,
                                    acquiredAt: nil, acquiredFrom: nil,
                                    addedAt: Date(timeIntervalSince1970: 0), variant: "holo")
        let parsed = try XCTUnwrap(LabelPayload.parse(LabelPayload.url(for: entry)))
        XCTAssertEqual(parsed.cardId, "base1-4")
        XCTAssertEqual(parsed.printing, .holo)
        XCTAssertEqual(parsed.condition, .lp)
        XCTAssertEqual(parsed.entryId, "entry-9")
    }

    // MARK: - Routing

    @MainActor
    func testALabelLinkRoutesToTheCardCarryingItsPrintingAndCondition() {
        let model = AppModel.makeDefault(skipFirebase: true)
        let url = LabelPayload.url(cardId: "base1-4", printing: .reverseHolo,
                                   condition: .mp, entryId: "e1")
        model.handleDeepLink(url)
        XCTAssertEqual(model.pendingCardId, "base1-4")
        XCTAssertEqual(model.pendingCardHighlight?.printing, .reverseHolo)
        XCTAssertEqual(model.pendingCardHighlight?.condition, .mp)
    }

    /// A plain share link must still route exactly as it does today — no highlight, no change.
    /// An EMPTY highlight would be a behaviour change dressed as a nil check: it would push a
    /// different `CardID` value for every ordinary link in the app.
    @MainActor
    func testAPlainShareLinkStillRoutesWithNoHighlight() {
        let model = AppModel.makeDefault(skipFirebase: true)
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/base1-4")!)
        XCTAssertEqual(model.pendingCardId, "base1-4")
        XCTAssertNil(model.pendingCardHighlight)
    }

    /// Rule 2 end to end: a v2 label routes to the card with nothing interpreted.
    @MainActor
    func testAFutureVersionLabelStillRoutesToTheCard() {
        let model = AppModel.makeDefault(skipFirebase: true)
        model.handleDeepLink(URL(string: "https://thetinapp.com/c/base1-4?v=7&p=holo&c=NM")!)
        XCTAssertEqual(model.pendingCardId, "base1-4")
        XCTAssertNil(model.pendingCardHighlight)
    }

    /// `LabelPayload.parse` is host-locked because a label is a printed contract; the deep-link
    /// handler is not, and must not become so on the back of this feature.
    @MainActor
    func testADeepLinkFromAnotherHostStillOpensItsCard() {
        let model = AppModel.makeDefault(skipFirebase: true)
        model.handleDeepLink(URL(string: "https://example.com/c/base1-4")!)
        XCTAssertEqual(model.pendingCardId, "base1-4")
        XCTAssertNil(model.pendingCardHighlight)
    }

    /// The route is what carries it — a highlight that never reaches `CardID` shows nothing.
    func testTheRouteCarriesTheHighlight() {
        let highlight = CardHighlight(printing: .holo, condition: .nm)
        XCTAssertEqual(CardID(raw: "base1-4", highlight: highlight).highlight?.printing, .holo)
        XCTAssertNil(CardID(raw: "base1-4").highlight, "every existing call site stays unhighlighted")
    }

    func testAnEmptyHighlightIsNoHighlight() {
        XCTAssertNil(CardHighlight(printing: nil, condition: nil))
        XCTAssertNotNil(CardHighlight(printing: nil, condition: .nm))
        XCTAssertNotNil(CardHighlight(printing: .holo, condition: nil))
    }
}
