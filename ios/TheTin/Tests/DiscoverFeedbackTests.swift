import XCTest
@testable import TheTin

final class DiscoverFeedbackTests: XCTestCase {
    private func card(_ id: String, rarity: String? = nil) -> CardRecord {
        CardRecord(id: id, setId: "S", number: "1", name: id, hp: nil, types: [],
                   rarity: rarity, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    // MARK: each reason moves exactly one dimension

    func testTooExpensiveSetsAPriceCeilingAndNothingElse() {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive], cards: ["a": card("a", rarity: "Common")],
                                        dexIds: ["a": [25]], prices: ["a": 400])
        XCTAssertEqual(f.priceCeiling, 400)
        XCTAssertTrue(f.species.isEmpty)
        XCTAssertTrue(f.generations.isEmpty)
        XCTAssertTrue(f.rarities.isEmpty)
    }

    func testNotMySpeciesPenalisesOnlyTheSpecies() {
        let f = DiscoverFeedback.derive(reasons: ["a": .notMySpecies], cards: ["a": card("a", rarity: "Common")],
                                        dexIds: ["a": [25]], prices: ["a": 5])
        XCTAssertEqual(f.species[25], 0.5)
        XCTAssertNil(f.priceCeiling)
        XCTAssertTrue(f.rarities.isEmpty)
    }

    func testWrongEraPenalisesTheGenerationTheCardBelongsTo() {
        let f = DiscoverFeedback.derive(reasons: ["a": .wrongEra], cards: ["a": card("a")],
                                        dexIds: ["a": [880]], prices: [:])   // 880 -> Gen 8
        XCTAssertEqual(f.generations[8], 0.5)
        XCTAssertTrue(f.species.isEmpty)
    }

    func testNotMyKindPenalisesTheRarity() {
        let f = DiscoverFeedback.derive(reasons: ["a": .notMyKind], cards: ["a": card("a", rarity: "Common")],
                                        dexIds: [:], prices: [:])
        XCTAssertEqual(f.rarities["Common"], 0.5)
    }

    // MARK: compounding

    func testRepeatedRejectionsCompound() throws {
        let f = DiscoverFeedback.derive(
            reasons: ["a": .notMySpecies, "b": .notMySpecies],
            cards: ["a": card("a"), "b": card("b")],
            dexIds: ["a": [25], "b": [25]], prices: [:])
        XCTAssertEqual(try XCTUnwrap(f.species[25]), 0.25, accuracy: 0.0001)
    }

    func testCompoundingStopsAtTheMinimum() throws {
        var reasons: [String: DismissReason] = [:], cards: [String: CardRecord] = [:], dex: [String: [Int]] = [:]
        for i in 0..<20 { reasons["c\(i)"] = .notMySpecies; cards["c\(i)"] = card("c\(i)"); dex["c\(i)"] = [25] }
        let f = DiscoverFeedback.derive(reasons: reasons, cards: cards, dexIds: dex, prices: [:])
        XCTAssertEqual(try XCTUnwrap(f.species[25]), DiscoverFeedback.minimumMultiplier, accuracy: 0.0001)
    }

    /// Saying "$400 is too much" after "$90 is too much" must not RAISE the ceiling back to $400.
    func testTheCheapestTooExpensiveRejectionWins() {
        let f = DiscoverFeedback.derive(
            reasons: ["a": .tooExpensive, "b": .tooExpensive],
            cards: ["a": card("a"), "b": card("b")],
            dexIds: [:], prices: ["a": 400, "b": 90])
        XCTAssertEqual(f.priceCeiling, 90)
    }

    func testAnUnpricedCardCannotSetACeiling() {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive], cards: ["a": card("a")],
                                        dexIds: [:], prices: [:])
        XCTAssertNil(f.priceCeiling)
    }

    func testDerivationIsDeterministicRegardlessOfDictionaryOrder() {
        let cards = ["a": card("a"), "b": card("b")]
        let prices = ["a": 400.0, "b": 90.0]
        let first = DiscoverFeedback.derive(reasons: ["a": .tooExpensive, "b": .tooExpensive],
                                            cards: cards, dexIds: [:], prices: prices)
        for _ in 0..<10 {
            XCTAssertEqual(DiscoverFeedback.derive(reasons: ["b": .tooExpensive, "a": .tooExpensive],
                                                   cards: cards, dexIds: [:], prices: prices), first)
        }
    }

    // MARK: applying

    func testApplyingToAProfileScalesOnlyTheNamedKeys() {
        var p = DiscoverAffinity.Profile()
        p.species = [25: 1.0, 6: 1.0]
        var f = DiscoverFeedback()
        f.species = [25: 0.5]
        let out = f.apply(to: p)
        XCTAssertEqual(out.species[25] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(out.species[6] ?? 0, 1.0, accuracy: 0.0001, "an untouched species must not move")
    }

    /// ⚠️ The penalty must NOT be re-normalized away. If rejecting the top species just promoted the
    /// next one to 1.0, the relative ordering — and therefore the ranking — would be unchanged, and
    /// the whole feature would be a no-op. This is the same class of bug as the inert first build.
    func testAPenaltyIsNotUndoneByRenormalization() {
        var p = DiscoverAffinity.Profile()
        p.species = [25: 1.0, 6: 0.8]
        var f = DiscoverFeedback()
        f.species = [25: 0.5]
        let out = f.apply(to: p)
        XCTAssertLessThan(out.species[25] ?? 0, out.species[6] ?? 0,
                          "the rejected species must fall BELOW one the user never rejected")
    }

    func testAPenaltyForSomethingNotInTheProfileIsIgnored() {
        var f = DiscoverFeedback()
        f.species = [999: 0.5]
        XCTAssertEqual(f.apply(to: DiscoverAffinity.Profile()).species[999], nil)
    }

    func testTheCeilingPullsTheBandDown() {
        var f = DiscoverFeedback()
        f.priceCeiling = 20
        let out = f.apply(to: PriceBand(p25: 5, p50: 15, p75: 50))
        XCTAssertEqual(out?.p75, 20)
        XCTAssertEqual(out?.p25, 5)
    }

    func testACeilingAboveTheBandChangesNothing() {
        var f = DiscoverFeedback()
        f.priceCeiling = 500
        XCTAssertEqual(f.apply(to: PriceBand(p25: 5, p50: 15, p75: 50)), PriceBand(p25: 5, p50: 15, p75: 50))
    }

    /// A ceiling under p25 must collapse the band, never invert it — `fit` computes a width from
    /// `p75 - p25` and a negative width is nonsense.
    func testACeilingBelowTheBandDoesNotInvertIt() {
        var f = DiscoverFeedback()
        f.priceCeiling = 2
        let out = try! XCTUnwrap(f.apply(to: PriceBand(p25: 5, p50: 15, p75: 50)))
        XCTAssertLessThanOrEqual(out.p25, out.p75)
        XCTAssertEqual(out.p75, 2)
    }

    func testNoBandStaysNoBand() {
        XCTAssertNil(DiscoverFeedback().apply(to: nil))
    }
}
