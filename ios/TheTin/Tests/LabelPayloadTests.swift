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

    // MARK: - The name, which exists only for the website

    /// The page is stateless and can't look a card up, so without `n` it can only say
    /// "A trading card" — which is what it said on the device (step 11).
    func testTheNameRidesAlongForTheWebsite() throws {
        let url = LabelPayload.url(cardId: "neo1-5", printing: .holo, condition: .nm,
                                   entryId: "e1", name: "Feraligatr")
        let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "n" }?.value
        XCTAssertEqual(n, "Feraligatr")
    }

    /// The APP must not read it. A name frozen onto a sticker goes stale the moment the catalog
    /// corrects one; the id is the truth and the app has the catalog.
    func testTheAppIgnoresTheNameEntirely() throws {
        let url = URL(string: "https://thetinapp.com/c/neo1-5?v=1&p=holo&c=NM&n=Not%20The%20Real%20Name")!
        let parsed = try XCTUnwrap(LabelPayload.parse(url))
        XCTAssertEqual(parsed.cardId, "neo1-5")
        XCTAssertEqual(parsed.printing, .holo)
    }

    /// Every character costs QR modules, and the name is the one parameter nothing functional
    /// depends on — so it is capped rather than allowed to bloat a code that must scan off a
    /// 0.75" square.
    func testAnAbsurdNameIsCappedRatherThanBloatingTheCode() throws {
        let url = LabelPayload.url(cardId: "neo1-5", printing: nil, condition: nil,
                                   entryId: nil, name: String(repeating: "z", count: 300))
        let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "n" }?.value
        XCTAssertEqual(n?.count, LabelPayload.maxNameLength)
        XCTAssertLessThan(url.absoluteString.count, 140, "a label URL stays a comfortable QR")
    }

    /// The website is stateless and a card id can never reach the CDN on its own, so the art has
    /// to travel on the URL — under `img`, which share links already carry and the page already
    /// renders. A new letter here would have meant a site change for no gain.
    func testTheArtRidesAlongUnderTheShareLinksOwnParameter() throws {
        let url = LabelPayload.url(cardId: "neo1-5", printing: .holo, condition: .nm, entryId: "e1",
                                   name: "Feraligatr",
                                   imageURL: "https://assets.tcgdex.net/en/neo/neo1/5/high.png")
        let img = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "img" }?.value
        XCTAssertEqual(img, "https://assets.tcgdex.net/en/neo/neo1/5/high.png")
        // …and the app still ignores it, exactly as it ignores `n`.
        XCTAssertEqual(try XCTUnwrap(LabelPayload.parse(url)).printing, .holo)
    }

    /// The whole payload has to stay a scannable 0.75" code. A worst case — every parameter
    /// present, a real UUID entry id, a capped name and a full TCGdex art URL — is ~200 bytes,
    /// which is QR version 9 (53 modules ≈ 14 mil printed). Below ~10 mil is where phones start
    /// to struggle, so this is the headroom, not the limit.
    func testAFullyLoadedLabelStaysAScannableCode() {
        let url = LabelPayload.url(cardId: "sv03.5-025", printing: .reverseHolo, condition: .nm,
                                   entryId: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                                   name: String(repeating: "z", count: LabelPayload.maxNameLength),
                                   imageURL: "https://assets.tcgdex.net/en/sv/sv03.5/025/high.png")
        XCTAssertLessThan(url.absoluteString.count, 260, "a label URL stays a comfortable QR")
    }

    /// A card the catalog lost still gets a sticker — that is exactly when a label matters most.
    func testNoNameIsFineAndOmitsTheParameterEntirely() throws {
        let url = LabelPayload.url(cardId: "ghost-1", printing: nil, condition: nil, entryId: nil)
        XCTAssertFalse(url.absoluteString.contains("n="))
        XCTAssertEqual(try XCTUnwrap(LabelPayload.parse(url)).cardId, "ghost-1")
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
