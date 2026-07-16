import Foundation

/// Distinct navigation value types. Pushing raw `String` for both sets and cards
/// collided two `navigationDestination(for: String.self)` in one NavigationStack,
/// routing every String to the root-closest destination (the blank card-detail bug).
struct SetID: Hashable { let raw: String }
struct CardID: Hashable { let raw: String }
struct DexID: Hashable { let raw: Int }

/// Marker route for the pinned virtual "Wanted" group (distinct from the String group-ids
/// used by real collection groups, to avoid a navigationDestination type collision).
struct WantedRoute: Hashable {}

/// Route to a stream's immersive "See all" page (destination added in Task 13).
struct StreamRoute: Hashable { let kind: DiscoverModel.StreamKind }
