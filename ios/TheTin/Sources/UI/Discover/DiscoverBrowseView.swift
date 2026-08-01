import SwiftUI

/// The filterable Browse deck (Discover's "Browse & filter" entry — distinct from the top-level
/// `BrowseView` tab in `UI/Browse`, which browses by set/pokedex/sealed rather than by filter).
/// Reuses `StreamView`, feeding it a `BrowseStream` built from the current `criteria`.
/// `.id(criteria)` rebuilds the deck (fresh pager, scroll reset) when filters change. A toolbar
/// button opens `BrowseFilterSheet`.
struct DiscoverBrowseView: View {
    let store: CatalogStore
    var collection: CollectionModel?
    var wants: WantsModel?

    @State private var criteria = BrowseCriteria()
    @State private var showFilters = false
    @State private var presets = BrowsePresetStore()
    /// Fresh per launch, so the deck doesn't open on the same cards every session. XORed with the
    /// criteria hash below so that a filter change — which restarts the deck at the top, since the
    /// result set is a different one — hands you a different opening than the filter you left.
    /// Stable within a session, which is what `LIMIT/OFFSET` paging needs.
    @State private var sessionSeed = Int.random(in: 1...Int.max)

    private var ownedIds: [String] { (collection?.entries ?? []).map(\.cardId) }

    var body: some View {
        StreamView(title: "Browse",
                   stream: BrowseStream(store: store, criteria: criteria, ownedIds: ownedIds,
                                        seed: sessionSeed ^ criteria.hashValue),
                   caption: caption,
                   store: store, wants: wants, collection: collection)
            .id(criteria)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Label("Filters", systemImage: criteria.isDefault
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                BrowseFilterSheet(criteria: $criteria, presets: presets,
                                  eras: (try? store.distinctEras()) ?? [])
            }
    }

    /// "Rarity · Series" under each card, whichever parts exist.
    private func caption(_ card: CardRecord) -> String? {
        let era = (try? store.set(id: card.setId))?.era
        let parts = [card.rarity, era].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
