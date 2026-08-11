import XCTest
import SwiftUI
import UIKit
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


    // MARK: each reason moves exactly one dimension


    // MARK: compounding

    func testRepeatedRejectionsCompound() throws {
        let f = DiscoverFeedback.derive(
            reasons: ["a": .notMySpecies, "b": .notMySpecies],
            cards: ["a": card("a"), "b": card("b")],
            dexIds: ["a": [25], "b": [25]], prices: [:])
        XCTAssertEqual(try XCTUnwrap(f.species[25]), 0.25, accuracy: 0.0001)
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


    // MARK: the hide-only reasons

    /// ⚠️ These two deliberately tune NOTHING, and Tomas's reasoning is why: *"maybe I just don't
    /// like that art by that artist but I like other art by that artist."* An artist penalty would
    /// be wrong and a rarity one would be guessing. The card is hidden by `dismissed`; the reason is
    /// recorded so a later version can learn from accumulated history without re-teaching.
    func testTheHideOnlyReasonsMoveNoDimension() {
        for reason in [DismissReason.dontLikeArt, .notWorthThisPrice] {
            let f = DiscoverFeedback.derive(reasons: ["a": reason], at: ["a": now],
                                            cards: ["a": card("a", rarity: "Ultra Rare")],
                                            dexIds: ["a": [880]], prices: ["a": 400], now: now)
            XCTAssertEqual(f, DiscoverFeedback(), "\(reason.rawValue) must tune nothing at all")
        }
    }

    /// Every reason still has to say what it does, including the ones that do nothing — an "effect"
    /// line that implies tuning which will not happen is worse than no panel at all.
    func testEveryReasonStatesItsEffectHonestly() {
        for reason in DismissReason.allCases {
            XCTAssertFalse(reason.label.isEmpty, reason.rawValue)
            XCTAssertFalse(reason.effect.isEmpty, reason.rawValue)
        }
        XCTAssertEqual(DismissReason.dontLikeArt.effect, "Hides this card")
        XCTAssertEqual(DismissReason.notWorthThisPrice.effect, "Hides this card")
    }

    /// ⚠️ `tooExpensive` was removed. A stored event carrying it must degrade to a plain hide rather
    /// than breaking the decode — the card stays hidden, no price cut is derived, which is exactly
    /// right now that `PriceTiers` states price visibly.
    func testTheRemovedTooExpensiveRawValueDecodesToNil() {
        XCTAssertNil(DismissReason(rawValue: "tooExpensive"))
        XCTAssertNil(DismissReason(rawValue: "notMyKind"))
    }

    // MARK: - The panel's chip width

    /// ⚠️ **These strings render in a 56.75pt chip, and length is a hard constraint there.**
    /// `CardFeedbackPanel`'s tightest home is a grid cell on a 375pt phone — SE 2nd/3rd gen, 13
    /// mini, XS, all supported by the iOS 17 target. "Less from this generation" (25 chars) needed
    /// a third line and truncated to "Less from this generati…", cutting exactly the tune-vs-hide
    /// distinction these strings exist to draw. It had done so since the panel shipped, invisibly,
    /// because the text was 9pt grey.
    ///
    /// ⚠️ **A character budget, deliberately, after three attempts to model the layout failed.**
    /// The obvious tests are all subtly wrong:
    ///
    /// 1. Render capped vs free and compare heights — `minimumScaleFactor` shrinks the capped
    ///    render, so the difference measures shrinking, not truncation. Failed on a good string.
    /// 2. Count wrapped lines at the `minimumScaleFactor(0.7)` floor of 7.7pt — too permissive.
    ///    Passed "Less from this generation" at a width where the renderer visibly truncated it;
    ///    SwiftUI does not reliably reach its stated floor while it is also wrapping.
    /// 3. Count wrapped lines at `.caption2`'s full 11pt — too strict. Rejected "Less of this
    ///    Pokémon", which renders correctly in two lines.
    ///
    /// The renderer's real behaviour sits between 2 and 3 and is not a layout constant you can
    /// compute against. So this asserts a budget anchored to `ImageRenderer` output at 375pt:
    ///
    /// | string | chars | renders |
    /// |---|---|---|
    /// | "Less from this gen" | 18 | whole |
    /// | "Less of this Pokémon" | 20 | whole |
    /// | "Less from this generation" | 25 | **truncates** |
    ///
    /// All three observed, not derived. **21–24 is unverified** — the budget is the largest length
    /// actually seen to render, not the smallest seen to fail.
    ///
    /// ⚠️ Character count ignores glyph width, so it is a proxy: a string of 18 wide glyphs could
    /// still overflow. Raising `maxEffectCharacters` is therefore a deliberate act that needs a
    /// fresh render, not a number to nudge until the test passes. The harness lives in the PR
    /// description for #149.
    private static let maxEffectCharacters = 20
    /// `shortLabel` carries its own hard newline, so the budget is per line.
    private static let maxLabelLineCharacters = 12

    func testEveryEffectStringFitsTheNarrowestChipItShipsIn() {
        for reason in DismissReason.allCases {
            XCTAssertLessThanOrEqual(
                reason.effect.count, Self.maxEffectCharacters,
                "\"\(reason.effect)\" is \(reason.effect.count) characters — it will truncate in "
                + "the 56.75pt chip on a 375pt phone. Shorten it, or re-render and raise the budget.")
        }
    }

    func testEveryShortLabelLineFitsTheNarrowestChipItShipsIn() {
        for reason in DismissReason.allCases {
            for line in reason.shortLabel.split(separator: "\n") {
                XCTAssertLessThanOrEqual(
                    line.count, Self.maxLabelLineCharacters,
                    "\"\(line)\" is \(line.count) characters — too wide for the 56.75pt chip.")
            }
        }
    }

    /// The string that caused this, kept as an explicit regression: if someone restores the longer
    /// wording the budget above catches it, and this says why in one line.
    func testTheWordingThatTruncatedIsStillTooLong() {
        XCTAssertGreaterThan("Less from this generation".count, Self.maxEffectCharacters)
    }
}
