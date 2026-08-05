import XCTest
@testable import TheTin

final class DiscoverFeedbackTests: XCTestCase {
    private func card(_ id: String, rarity: String? = nil) -> CardRecord {
        CardRecord(id: id, setId: "S", number: "1", name: id, hp: nil, types: [],
                   rarity: rarity, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    // MARK: decay

    func testWeightHalvesEveryHalfLife() {
        XCTAssertEqual(DiscoverFeedback.weight(age: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DiscoverFeedback.weight(age: 60 * 86_400), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DiscoverFeedback.weight(age: 120 * 86_400), 0.25, accuracy: 0.0001)
    }

    /// A future-dated event (a clock change, a restored backup) is full strength, never amplified.
    func testAFutureStampIsFullStrengthNotStronger() {
        XCTAssertEqual(DiscoverFeedback.weight(age: -86_400), 1.0, accuracy: 0.0001)
    }

    func testAFreshRejectionHitsHarderThanAnOldOne() throws {
        func speciesMultiplier(at stamp: Date) -> Double? {
            DiscoverFeedback.derive(reasons: ["a": .notMySpecies], at: ["a": stamp],
                                    cards: ["a": card("a")], dexIds: ["a": [25]],
                                    prices: [:], now: now).species[25]
        }
        let fresh = try XCTUnwrap(speciesMultiplier(at: now))
        let old = try XCTUnwrap(speciesMultiplier(at: daysAgo(120)))
        XCTAssertEqual(fresh, 0.5, accuracy: 0.0001, "a fresh 'no' is the full penalty")
        XCTAssertGreaterThan(old, fresh, "an old 'no' must weigh less")
        XCTAssertLessThan(old, 1.0, "but it has not vanished either")
    }

    /// ⚠️ The file already on the device carries no stamps. Treating unknown age as old would
    /// silently void every signal given before decay shipped.
    func testAMissingStampIsFullStrength() {
        let f = DiscoverFeedback.derive(reasons: ["a": .notMySpecies], at: [:],
                                        cards: ["a": card("a")], dexIds: ["a": [25]],
                                        prices: [:], now: now)
        XCTAssertEqual(f.species[25], 0.5)
    }

    func testDecayAppliesToEveryDimensionNotJustSpecies() throws {
        let f = DiscoverFeedback.derive(
            reasons: ["a": .wrongEra, "b": .notMyKind], at: ["a": daysAgo(120), "b": daysAgo(120)],
            cards: ["a": card("a"), "b": card("b", rarity: "Common")],
            dexIds: ["a": [880]], prices: [:], now: now)
        XCTAssertGreaterThan(try XCTUnwrap(f.generations[8]), 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(f.rarities["Common"]), 0.5)
    }

    // MARK: the ceiling needs corroboration

    /// ⚠️ Measured against the real collection: with `min()`, one tap on a $5.20 card set a
    /// PERMANENT ceiling that removed 66% of the deck — and that user's band `p25` was $5.13, so a
    /// ceiling any lower empties For You outright, silently and irreversibly.
    ///
    /// This is only dangerous now because the `varietyPicks` fix landed: every card shown is
    /// in-band, so every tap lands in the window where the blast radius is worst.
    func testOneTapSetsNoCeiling() {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive], at: ["a": now],
                                        cards: ["a": card("a")], dexIds: [:],
                                        prices: ["a": 5.20], now: now)
        XCTAssertNil(f.priceCeiling)
    }

    /// The ceiling is the SECOND-cheapest rejection, so with exactly two taps it is the higher of
    /// them. That leniency is deliberate: a ceiling that is too high shows a few unwanted cards,
    /// one that is too low empties the feature.
    func testTwoTapsSetTheCeilingAtTheSecondCheapest() throws {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive, "b": .tooExpensive],
                                        at: ["a": now, "b": now],
                                        cards: ["a": card("a"), "b": card("b")], dexIds: [:],
                                        prices: ["a": 50, "b": 20], now: now)
        XCTAssertEqual(try XCTUnwrap(f.priceCeiling), 50, accuracy: 0.0001)
    }

    /// ⚠️ THE CASE CORROBORATION ALONE DOES NOT FIX. A genuine $200 rejection plus one stray tap on
    /// a $6 card would give a $6 ceiling under `min()` — and under nearest-rank p25 too, which is
    /// the minimum for any sample of four or fewer. Second-cheapest discards the outlier.
    func testAStrayCheapTapAlongsideAGenuineRejectionIsDiscarded() throws {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive, "b": .tooExpensive],
                                        at: ["a": now, "b": now],
                                        cards: ["a": card("a"), "b": card("b")], dexIds: [:],
                                        prices: ["a": 200, "b": 6], now: now)
        XCTAssertEqual(try XCTUnwrap(f.priceCeiling), 200, accuracy: 0.0001)
    }

    /// The ceiling does NOT decay in value — a $30 ceiling drifting to $1,920 after six half-lives
    /// is nonsense. Events expire out of it instead, and expiry can drop it below corroboration.
    func testAnExpiredTapStopsCountingTowardTheCeiling() {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive, "b": .tooExpensive],
                                        at: ["a": now, "b": daysAgo(120)],
                                        cards: ["a": card("a"), "b": card("b")], dexIds: [:],
                                        prices: ["a": 50, "b": 20], now: now)
        XCTAssertNil(f.priceCeiling, "one live event left is not corroboration")
    }

    /// With several genuine rejections the ceiling settles on the cheapest of THOSE, so the cut
    /// tracks what the user actually rejects rather than their single worst mistap.
    func testTheCeilingTracksTheCheapestGenuineRejection() throws {
        let ids = ["a", "b", "c", "d", "e"]
        let f = DiscoverFeedback.derive(
            reasons: Dictionary(uniqueKeysWithValues: ids.map { ($0, DismissReason.tooExpensive) }),
            at: Dictionary(uniqueKeysWithValues: ids.map { ($0, now) }),
            cards: Dictionary(uniqueKeysWithValues: ids.map { ($0, card($0)) }),
            dexIds: [:], prices: ["a": 6, "b": 30, "c": 35, "d": 40, "e": 200], now: now)
        XCTAssertEqual(try XCTUnwrap(f.priceCeiling), 30, accuracy: 0.0001,
                       "the $6 mistap is discarded; $30 is the cheapest corroborated rejection")
    }

    /// The invariant that actually holds, and the one worth having: **the single cheapest rejection
    /// never sets the ceiling on its own.** (A stronger-sounding "at least two rejections sit at or
    /// above the ceiling" is FALSE at n = 2, where second-cheapest is the maximum — a test asserting
    /// it failed here and was wrong, not the code.)
    func testTheCheapestRejectionAloneNeverSetsTheCeiling() throws {
        for prices in [[10.0, 20], [5.0, 5, 5], [1.0, 2, 3, 4, 5], [99.0, 1, 50, 2]] {
            let ids = prices.indices.map { "c\($0)" }
            let f = DiscoverFeedback.derive(
                reasons: Dictionary(uniqueKeysWithValues: ids.map { ($0, DismissReason.tooExpensive) }),
                at: Dictionary(uniqueKeysWithValues: ids.map { ($0, now) }),
                cards: Dictionary(uniqueKeysWithValues: ids.map { ($0, card($0)) }),
                dexIds: [:],
                prices: Dictionary(uniqueKeysWithValues: zip(ids, prices)), now: now)
            let ceiling = try XCTUnwrap(f.priceCeiling)
            if Set(prices).count > 1 {
                XCTAssertGreaterThan(ceiling, prices.min() ?? 0, "\(prices)")
            } else {
                XCTAssertEqual(ceiling, prices[0], accuracy: 0.0001, "\(prices)")
            }
        }
    }

    // MARK: each reason moves exactly one dimension

    /// ⚠️ Rewritten: this used to assert that ONE tap sets the ceiling, which is the behaviour the
    /// corroboration guard removes. See `testOneTapSetsNoCeiling` for why.
    func testTooExpensiveMovesThePriceAxisAndNothingElse() {
        let f = DiscoverFeedback.derive(reasons: ["a": .tooExpensive, "b": .tooExpensive],
                                        cards: ["a": card("a", rarity: "Common"), "b": card("b", rarity: "Common")],
                                        dexIds: ["a": [25], "b": [25]], prices: ["a": 400, "b": 380])
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

    /// ⚠️ Rewritten. This asserted "the cheapest rejection wins" — `min()` semantics — which is
    /// exactly the rule that let one mistap gut a real deck. Order of statement still does not
    /// matter, which is what this now pins.
    func testTheCeilingDoesNotDependOnTheOrderOfStatement() {
        let a = DiscoverFeedback.derive(
            reasons: ["a": .tooExpensive, "b": .tooExpensive],
            cards: ["a": card("a"), "b": card("b")], dexIds: [:], prices: ["a": 400, "b": 90])
        let b = DiscoverFeedback.derive(
            reasons: ["a": .tooExpensive, "b": .tooExpensive],
            cards: ["a": card("a"), "b": card("b")], dexIds: [:], prices: ["a": 90, "b": 400])
        XCTAssertEqual(a.priceCeiling, b.priceCeiling)
        XCTAssertEqual(a.priceCeiling, 400)
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

    // MARK: the ceiling must be a HARD cut

    /// ⚠️ Regression guard, from real data 2026-08-04. That user's band was $5.13–$33.55 while the
    /// cards they were rejecting were $80–$352 — all already above p75, so tightening the band
    /// changed nothing, and they were already at the 0.15 price floor yet still ranked top because
    /// a 3x species match swamps any multiplier. "Too expensive" has to exclude, not nudge.
    func testACardAtOrAboveTheCeilingIsExcludedOutright() {
        var f = DiscoverFeedback()
        f.priceCeiling = 80
        XCTAssertTrue(f.excludes(price: 80), "at the ceiling counts as too expensive")
        XCTAssertTrue(f.excludes(price: 352))
        XCTAssertFalse(f.excludes(price: 79.99))
    }

    func testNoCeilingExcludesNothing() {
        XCTAssertFalse(DiscoverFeedback().excludes(price: 10_000))
    }

    func testAnUnpricedCardIsNeverExcludedByTheCeiling() {
        // No price is not a high price — a card we can't price must not vanish.
        var f = DiscoverFeedback()
        f.priceCeiling = 20
        XCTAssertFalse(f.excludes(price: nil))
    }

    func testNoBandStaysNoBand() {
        XCTAssertNil(DiscoverFeedback().apply(to: nil))
    }
}
