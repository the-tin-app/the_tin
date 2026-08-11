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

    // MARK: - The panel's chip width, measured

    /// ⚠️ **Every `effect` string is rendered in a ~73pt chip, and two of them do not fit on one
    /// line at any legible size.** `CardFeedbackPanel` ships at two widths: ~420pt over the 1-up
    /// deck, and a ~172pt grid cell where each of the four chips is about 73pt. "Less from this
    /// generation" truncated to "Less from this ge…" there — cutting exactly the tune-vs-hide
    /// distinction the line exists to draw — and it had done so since the panel shipped. It hid
    /// because the text was 9pt grey; rendering it at `.caption2` only made it visible.
    ///
    /// The fix is `lineLimit(2)`. Truncation happens when the string still needs a third line at
    /// the SMALLEST size `minimumScaleFactor(0.7)` permits, so that is what gets measured —
    /// caption2 is 11pt, so the floor is 7.7pt.
    ///
    /// ⚠️ The obvious version of this test — render capped, render free, compare heights — is a
    /// FALSE POSITIVE and was written first. `minimumScaleFactor` shrinks the capped render to fit,
    /// so it is legitimately shorter than a free one that wrapped at full size; the difference
    /// measures shrinking, not truncation. It failed on a string that renders perfectly.
    ///
    /// Guards the copy as much as the layout: a longer `effect` string fails here.
    @MainActor
    func testEveryEffectStringFitsTheNarrowestChipItShipsIn() throws {
        for reason in DismissReason.allCases {
            XCTAssertLessThanOrEqual(
                linesNeeded(reason.effect, width: Self.chipWidth), 2,
                "\(reason.effect) needs a third line at \(Self.chipWidth)pt — it will truncate")
        }
    }

    /// The labels share the chip and carry a hard newline of their own, so they get the same check.
    @MainActor
    func testEveryShortLabelFitsTheNarrowestChipItShipsIn() throws {
        for reason in DismissReason.allCases {
            XCTAssertLessThanOrEqual(
                linesNeeded(reason.shortLabel, width: Self.chipWidth), 2,
                "\(reason.shortLabel.replacingOccurrences(of: "\n", with: " ")) truncates at "
                + "\(Self.chipWidth)pt")
        }
    }

    /// 172pt panel − 10pt padding each side = 152; two columns at 6pt spacing → 73pt.
    private static let chipWidth: CGFloat = 73
    /// `.caption2` at the default content size, times `minimumScaleFactor(0.7)`.
    private static let floorPointSize: CGFloat = 11 * 0.7

    /// Lines the string wraps to at the smallest permitted size, by measuring against the height
    /// of a single line of the same font rather than assuming a line height.
    @MainActor
    private func linesNeeded(_ string: String, width: CGFloat) -> Int {
        let oneLine = renderedHeight("X", width: width)
        return Int((renderedHeight(string, width: width) / oneLine).rounded())
    }

    @MainActor
    private func renderedHeight(_ string: String, width: CGFloat) -> CGFloat {
        let text = Text(string)
            .font(.system(size: Self.floorPointSize))
            .multilineTextAlignment(.center)
        let host = UIHostingController(rootView: text.frame(width: width))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
