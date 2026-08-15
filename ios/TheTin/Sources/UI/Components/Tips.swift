import SwiftUI
import TipKit

/// The four things a first-run user could not work out on their own (feedback, 2026-08-12).
///
/// These are contextual tips, NOT a tour. Each one is presented inline (`TipView`), next to the
/// control it explains, and TipKit shows it once. Not `.popoverTip`: that doesn't reliably
/// present on a control inside a `Form` `Section`/`List`, or on a `Menu` inside a `ToolbarItem`
/// (confirmed by direct test on the toolbar `Menu`, iOS 26 simulator; inferred at the `Form`
/// `Section` and `List` anchors from the same limitation) — `TipView` is TipKit's documented
/// inline alternative for exactly those contexts.
///
/// A tour was considered and rejected: three of the six things reported as confusing were
/// navigation and naming defects, and those are fixed in place — a tour explaining a mismatched
/// label is a maintained explanation of a bug.
///
/// ⚠️ **No tip may promise speed or notification.** eBay's saved search is a DAILY email and the
/// app sends nothing. `TipsTests.testNoTipPromisesSpeed` is the guard, and `HuntRow`'s header
/// carries the same warning.

/// Each tip's copy is a `static let` so `TipsTests` can assert it without introspecting a
/// SwiftUI `Text`. The constant is the source of truth; `message` just wraps it.

/// Grail sits above High in the priority picker with nothing saying what it means.
struct GrailTip: Tip {
    static let body = "The card you'd most want, whether or not you're buying one right now. "
        + "Hunting is the other question — that's the card you're actually shopping for."
    var title: Text { Text("What's a Grail?") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "star") }
}

/// Hunting is the gate on the eBay search, and the search is invisible until it's on.
struct HuntingTip: Tip {
    static let body = "Hunting with a price target gives this card a one-tap eBay "
        + "search at your budget. It runs until you switch it off."
    var title: Text { Text("Hunting means you're buying") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "binoculars") }
}

/// Watching reads as a fourth list beside Wishlist and For Trade. It isn't one.
struct WatchingTip: Tip {
    static let body = "Not another list — it's what the cards on your Wishlist have been doing "
        + "lately, so a card you're after that's dropped turns up here."
    // Just the name. "Watching is the news" was trying to be clever, and the first user to read
    // it said so — the body already carries the explanation, so the title only has to label.
    var title: Text { Text("Watching") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "binoculars") }
}

/// Centring is measured on the plate the scan already produced, so the shot has to be worth
/// measuring on — taught in the viewfinder, where that can still be acted on.
///
/// ⚠️ Says "measure", never "grade". The app measures two border ratios and stops there; corners,
/// edges and surface are not assessed and no grade is predicted (research, 2026-08-14). Copy that
/// implied otherwise would be a promise the scanner cannot keep.
struct CenteringScanTip: Tip {
    static let body = "Lay the card flat and hold the phone square above it, and your scan keeps "
        + "a picture you can measure the borders on afterwards in Review scans."
    var title: Text { Text("Centering, from your own scan") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "square.dashed") }
}

/// "Measure centering" is a button whose whole interaction — drag four lines — is invisible until
/// you tap it. This is what makes the row worth tapping.
struct CenteringReviewTip: Tip {
    static let body = "Tap it to see your scan with four lines on it. Drag each one onto the "
        + "edge of the printed border and the ratio follows — 50/50 is dead centre. It measures "
        + "centering only, and nothing is recorded until you place the lines yourself."
    var title: Text { Text("What the centering line means") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "square.dashed") }
}

/// A line placed perfectly on the middle of a card's edge still drifts off it toward the corners,
/// and there is no way to tell from the screen whether that is the app being wrong or the picture
/// being curved. It is the picture: a phone lens bows straight edges slightly, and a homography
/// maps straight lines to straight lines, so perspective correction cannot take the curve out.
///
/// Unexplained, it reads as a bug in the one screen whose entire purpose is being trustworthy —
/// which is why this exists (Tomas, 2026-08-15). It also carries the instruction that keeps the
/// bow out of the answer: matched at the same point on each edge, the curve is near-identical for
/// a pair of lines a few pixels apart, so it cancels out of the width between them.
struct CenteringLensBowTip: Tip {
    static let body = "Your phone's lens bows straight edges very slightly, so a line sitting "
        + "right on the middle of an edge can look a little off at the corners. That's the lens, "
        + "not your card — line each pair up at the middle and it cancels out of the numbers."
    var title: Text { Text("Why the corners look off") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "camera.metering.center.weighted") }
}

/// Editing an owned card was reported as undiscoverable. #152 added the tap-mode picker; this
/// points at it rather than adding a second way to do the same thing.
///
/// Presented as an inline `TipView` at the top of the list rather than `.popoverTip` on the
/// toolbar `Menu` it explains — `.popoverTip` doesn't reliably present on a `Menu` inside a
/// `ToolbarItem` (confirmed by direct test). The copy says "the menu above" rather than "here"
/// because of that: the tip sits below the control it's pointing at, not beside it.
struct EditCardTip: Tip {
    static let body = "Switch what a tap does in the menu above, then tap any card to edit its "
        + "condition, what you paid, or its photos."
    var title: Text { Text("Editing a card you own") }
    var message: Text? { Text(Self.body) }
    var image: Image? { Image(systemName: "pencil") }
}
