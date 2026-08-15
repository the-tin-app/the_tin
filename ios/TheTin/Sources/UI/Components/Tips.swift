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
