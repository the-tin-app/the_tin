import Foundation

/// Distinct navigation value types. Pushing raw `String` for both sets and cards
/// collided two `navigationDestination(for: String.self)` in one NavigationStack,
/// routing every String to the root-closest destination (the blank card-detail bug).
struct SetID: Hashable { let raw: String }

/// Which copy or printing the route is about, carried along so card detail opens already scoped
/// to it — a printed label's copy, a tin row's entry, or the printing a Movers row quoted. Both
/// halves are optional: a label whose entry has since been deleted, or a payload from a version
/// we don't read, still opens the card plainly.
///
/// Without it a row and the card it opens disagree: the row quotes the copy you own (or the
/// printing that moved), the card headlines its rarity-default printing, and "+38%" in the list
/// becomes "+1.2%" one tap later with nothing on screen to say why.
struct CardHighlight: Hashable {
    let printing: CardVariant?
    let condition: CardCondition?

    /// nil when the link said nothing about the copy — a plain share link, or a label from a
    /// version we don't read. "Highlight nothing" and "no highlight" must be the same value, or
    /// every ordinary `/c/<id>` link starts carrying an empty payload down the route.
    init?(printing: CardVariant?, condition: CardCondition?) {
        guard printing != nil || condition != nil else { return nil }
        self.printing = printing
        self.condition = condition
    }

    /// What an owned entry recorded about itself — the same two facts its tin row prices from.
    init?(entry: CollectionEntry) {
        self.init(printing: entry.variantValue, condition: entry.conditionValue)
    }
}

/// `highlight` is DEFAULTED so a route that knows nothing about the copy stays `CardID(raw:)`.
/// Only the Tin's and Movers' `navigationDestination(for: CardID.self)` forward it — the routes
/// into the other four never carry one.
struct CardID: Hashable {
    let raw: String
    var highlight: CardHighlight? = nil
}
struct DexID: Hashable { let raw: Int }

/// So a card can also be *presented* (`.sheet(item:)`), not only pushed — the scanner's look-up
/// mode shows a card over the live camera rather than navigating away from it.
extension CardID: Identifiable { var id: String { raw } }

/// Marker route for the pinned virtual "Wishlist" group (distinct from the String group-ids
/// used by real collection groups, to avoid a navigationDestination type collision).
///
/// `scope` opens the screen on a specific segment instead of whatever was last used. Carried on
/// the ROUTE rather than written into `@AppStorage` by the caller before navigating: the stored
/// value is the user's own last choice, and a link that silently rewrites it would change what
/// their pinned Wishlist row opens on next time — which is the class of bug #159 fixed.
struct WantedRoute: Hashable {
    var scope: WantedView.Scope? = nil
}

/// Route to the Watching screen: what the cards you said you care about have been doing.
struct WatchingRoute: Hashable {}

/// Route to a stream's immersive "See all" page (destination added in Task 13).
struct StreamRoute: Hashable { let kind: DiscoverModel.StreamKind }

/// Route to the filterable Browse deck.
struct BrowseRoute: Hashable {}

/// One shelf's "See all" — the existing immersive deck over a single For You row. Carries the
/// shelf id rather than the shelf itself so the route stays a small, stable value while the shelves
/// behind it are rebuilt on every signal change.
struct ShelfRoute: Hashable { let shelfId: String }
