import XCTest
@testable import TheTin

final class HuntRowTests: XCTestCase {
    private func card(number: String, name: String = "Charizard",
                      setId: String = "base1") -> CardRecord {
        CardRecord(id: "\(setId)-\(number)", setId: setId, number: number, name: name, hp: nil,
                   types: [], rarity: nil, artist: nil, imageBase: nil, imageUrl: nil,
                   tcgplayerId: nil)
    }
    private func hunting(target: Double? = 300) -> WantEntry {
        WantEntry(targetUsd: target, hunt: Hunt(minCondition: .hp))
    }
    private func nkw(_ url: URL) throws -> String {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "_nkw" }?.value)
    }

    /// The whole point of the row's button. The denominator shipped as `nil` once — every hunt
    /// searched a bare "4", which eBay ANDs against item counts, prices and "4 cards" — so this
    /// asserts the value reaches the URL, not just that the builder can accept one.
    func testHuntURLCarriesThePrintedDenominator() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "4"),
                                                        entry: hunting(),
                                                        setName: "Base Set", printedTotal: 102))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("4/102"), q)
    }

    /// Promo numbers are already unique, and "SWSH223/307" matches no real listing title.
    func testHuntURLOmitsTheDenominatorForAPromoNumber() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "SWSH223",
                                                                  name: "Mewtwo V",
                                                                  setId: "swshp"),
                                                        entry: hunting(),
                                                        setName: "SWSH Black Star Promos",
                                                        printedTotal: 307))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("SWSH223"))
        XCTAssertFalse(q.contains("/307"), q)
    }

    /// An unknown printed total emits the bare number rather than guessing one — a wrong
    /// denominator returns zero results silently, which is worse than a loose query.
    func testHuntURLOmitsTheDenominatorWhenThePrintedTotalIsUnknown() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "4"),
                                                        entry: hunting(),
                                                        setName: "Base Set", printedTotal: nil))
        let q = try nkw(url)
        XCTAssertTrue(q.contains("4"))
        XCTAssertFalse(q.contains("4/"), q)
    }

    /// The budget is the price ceiling, and a card that isn't hunted has no row and no link.
    func testHuntURLPassesTheBudgetAndSkipsUnhuntedCards() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "4"),
                                                        entry: hunting(target: 300),
                                                        setName: "Base Set", printedTotal: 102))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "_udhi" }?.value, "300")

        XCTAssertNil(HuntRow.huntURL(card: card(number: "4"), entry: WantEntry(),
                                             setName: "Base Set", printedTotal: 102))
        XCTAssertNil(HuntRow.huntURL(card: card(number: "4"), entry: nil,
                                             setName: "Base Set", printedTotal: 102))
    }

    /// Direction and whole percent. Shared by the Hunting row and Watching's drops section, so
    /// the two cannot phrase the same number differently.
    func testDeltaReadsDirectionAndWholePercent() {
        XCTAssertEqual(HuntRow.delta(-0.1449).text, "↓14% this week")
        XCTAssertEqual(HuntRow.delta(0.034).text, "↑3% this week")
        XCTAssertFalse(HuntRow.delta(-0.1449).isFlat)
    }

    /// ⚠️ A move that rounds to 0% must not carry an arrow or a colour. Shipped briefly showing
    /// "↓0% this week" in green on a card that had barely moved — the arrow claimed a direction
    /// the number itself denied. The flat threshold follows the DISPLAY precision: this renders
    /// whole percent, so anything under 0.5% is flat.
    func testAMoveThatRoundsToZeroIsFlatAndNeutral() {
        for pct in [-0.004, 0.004, 0.0, -0.0001] {
            let d = HuntRow.delta(pct)
            XCTAssertTrue(d.isFlat, "\(pct) should be flat")
            XCTAssertEqual(d.text, "unchanged this week")
        }
        // …and 0.5% rounds up to 1%, so it is a real move again.
        XCTAssertFalse(HuntRow.delta(-0.005).isFlat)
        XCTAssertEqual(HuntRow.delta(-0.005).text, "↓1% this week")
    }

    /// The floor rose to 0.35 on 2026-08-01 after a hand count against live eBay. Pinned at the
    /// URL because it is the ONLY defence against counterfeits and mislabelled reprints —
    /// sellers put the right set name and collector number on the wrong card, so no keyword
    /// can separate them and `huntNegativeKeywords` must not be extended to try.
    func testHuntFloorsAtThirtyFivePercentOfMarket() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "4"),
                                                entry: hunting(target: 700),
                                                setName: "Base Set", printedTotal: 102,
                                                marketUsd: 850))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "_udlo" }?.value, "297.50")
    }

    /// A hunt for Charmander 168 (151) opened on the KOREAN card on 2026-08-01 — same set, same
    /// number, correct in every other respect. The catalog is English-only, so a non-English
    /// printing is never what the hunt meant. Unlike counterfeits, sellers DO say "Korean", so
    /// a keyword works here where it cannot work there.
    func testHuntExcludesNonEnglishPrintings() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "168", name: "Charmander"),
                                                entry: hunting(target: 300),
                                                setName: "151", printedTotal: 165))
        let q = try nkw(url)
        for language in ["korean", "japanese", "chinese", "german"] {
            XCTAssertTrue(q.contains("-\(language)"), "missing -\(language) in: \(q)")
        }
    }

    /// The collision rule still applies: a negative whose every word is a required positive
    /// would cancel the whole query. A Japanese-set hunt must not exclude "japanese".
    func testALanguageInTheSetNameIsNotExcluded() throws {
        let url = try XCTUnwrap(HuntRow.huntURL(card: card(number: "1", name: "Japanese Promo"),
                                                entry: hunting(target: 50),
                                                setName: nil, printedTotal: nil))
        let q = try nkw(url)
        XCTAssertFalse(q.contains("-japanese"), "would cancel every result: \(q)")
        XCTAssertTrue(q.contains("-korean"), q)
    }
}
