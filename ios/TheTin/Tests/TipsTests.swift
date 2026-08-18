import XCTest
import TipKit
@testable import TheTin

/// The tips carry the vocabulary a first-run user could not derive from the UI (2026-08-12
/// feedback: "no idea what the grail was, what hunting was").
///
/// This asserts the COPY, not the presentation — TipKit owns when a tip shows, and testing its
/// display rules would be testing Apple's framework. What can break here is copy drifting back
/// out of sync with the names on screen, which is exactly what caused the confusion.
final class TipsTests: XCTestCase {
    /// Every tip's copy, by name for legible failures. Reads the `body` constants rather than
    /// introspecting `Text` — `String(describing:)` on a SwiftUI `Text` reaches into framework
    /// internals and would break on an OS update with nothing to do with this app.
    private let all: [(String, String)] = [
        ("grail", GrailTip.body), ("hunting", HuntingTip.body),
        ("watching", WatchingTip.body), ("edit", EditCardTip.body),
        ("centeringScan", CenteringScanTip.body), ("centeringReview", CenteringReviewTip.body),
        ("centeringLensBow", CenteringLensBowTip.body),
    ]

    /// ⚠️ The scanner measures centering and nothing else — no corners, edges or surface, and no
    /// predicted grade. A tip that said "grade" would promise the one thing we deliberately do not
    /// do, and it is the claim a cardholder would act on with real money.
    func testTheCenteringTipsPromiseNoGrade() {
        for (name, body) in [("centeringScan", CenteringScanTip.body),
                             ("centeringReview", CenteringReviewTip.body),
                             ("centeringLensBow", CenteringLensBowTip.body)] {
            for word in ["PSA", "grade it", "will grade", "gem", "mint"] {
                XCTAssertFalse(body.lowercased().contains(word.lowercased()),
                               "\(name) tip implies grading with “\(word)”: \(body)")
            }
        }
    }

    /// The two concepts are orthogonal and the copy has to say so — a grail you can't afford
    /// isn't hunting. See `WantEntry.swift`, where this distinction is defended.
    func testTheGrailTipDistinguishesItFromHunting() {
        XCTAssertTrue(GrailTip.body.contains("Hunting"),
                      "the grail tip must contrast with hunting: \(GrailTip.body)")
    }

    /// The hunting tip is the only place the eBay search is explained, since the search itself
    /// only appears once a hunt exists.
    func testTheHuntingTipMentionsTheSearch() {
        XCTAssertTrue(HuntingTip.body.contains("eBay"),
                      "the hunting tip must name the search: \(HuntingTip.body)")
    }

    /// ⚠️ No tip may promise speed. eBay's saved-search alert is a DAILY email and there is no
    /// faster free route — see `HuntRow`'s warning.
    func testNoTipPromisesSpeed() {
        let banned = ["instant", "immediately", "real-time", "realtime", "alert you", "notify"]
        for (name, body) in all {
            for word in banned {
                XCTAssertFalse(body.lowercased().contains(word),
                               "\(name) tip promises speed with “\(word)”: \(body)")
            }
        }
    }

    /// Task 1 made "Wishlist" the single name. A tip that says "Wanted" would reintroduce
    /// exactly the mismatch that task removed.
    func testNoTipUsesTheRetiredName() {
        for (name, body) in all {
            XCTAssertFalse(body.contains("Wanted"), "\(name) tip uses the retired name: \(body)")
        }
    }
}
