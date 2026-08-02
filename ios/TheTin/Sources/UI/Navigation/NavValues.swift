import Foundation

/// Distinct navigation value types. Pushing raw `String` for both sets and cards
/// collided two `navigationDestination(for: String.self)` in one NavigationStack,
/// routing every String to the root-closest destination (the blank card-detail bug).
struct SetID: Hashable { let raw: String }
struct CardID: Hashable { let raw: String }
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
