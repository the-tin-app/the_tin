import Foundation

/// Distinct navigation value types. Pushing raw `String` for both sets and cards
/// collided two `navigationDestination(for: String.self)` in one NavigationStack,
/// routing every String to the root-closest destination (the blank card-detail bug).
struct SetID: Hashable { let raw: String }

/// What a printed label knows about the particular copy in your hand, carried along the route so
/// card detail can open already scoped to it. Both halves are optional: a label whose entry has
/// since been deleted, or a payload from a version we don't read, still opens the card plainly.
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
}

/// `highlight` is DEFAULTED so every existing `CardID(raw:)` call site is untouched — six
/// `navigationDestination(for: CardID.self)` sites exist and only the Tin's forwards it.
struct CardID: Hashable {
    let raw: String
    var highlight: CardHighlight? = nil
}
struct DexID: Hashable { let raw: Int }

/// So a card can also be *presented* (`.sheet(item:)`), not only pushed — the scanner's look-up
/// mode shows a card over the live camera rather than navigating away from it.
extension CardID: Identifiable { var id: String { raw } }

/// Marker route for the pinned virtual "Wanted" group (distinct from the String group-ids
/// used by real collection groups, to avoid a navigationDestination type collision).
struct WantedRoute: Hashable {}

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
