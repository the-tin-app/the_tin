import SwiftUI

/// For You's "See all": one row per shelf, each with its own "See all" into the existing deck.
///
/// This is where the reason becomes visible. In the previous design the reason was a per-card
/// caption and the structure that actually chose the cards — `perGroupCap: 3` on set / artist /
/// species — had no surface at all. Here the row header *is* the reason.
struct ForYouShelvesView: View {
    let shelves: [Shelf]
    let store: CatalogStore
    var wants: WantsModel?
    var collection: CollectionModel?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(shelves) { shelf in
                    ShelfRow(shelf: shelf, store: store, wants: wants, collection: collection)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("For You")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShelfRow: View {
    let shelf: Shelf
    let store: CatalogStore
    var wants: WantsModel?
    var collection: CollectionModel?

    @State private var cards: [CardRecord] = []
    @State private var prices: [String: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shelf.title).font(.title3.bold())
                Spacer()
                NavigationLink(value: ShelfRoute(shelfId: shelf.id)) {
                    Text("See all ›").font(.subheadline)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                // ⚠️ LazyHStack, never HStack. The Connections row's non-lazy HStack built every
                // tile of a 1,767-card artist spotlight at once and took the app out with a jetsam
                // kill that SIGKILL guarantees Crashlytics never reports.
                LazyHStack(spacing: 12) {
                    if cards.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in SkeletonTile() }
                    }
                    ForEach(cards) { card in
                        DiscoverTile(card: card, value: prices[card.id], wants: wants,
                                     collection: collection, store: store)
                    }
                }
                .padding(.horizontal)
            }
        }
        // The ids are already chosen; only the records are read, and only for this row. Off-main
        // because `cards(ids:)` is a disk read and this runs while the user is scrolling.
        .task(id: shelf.id) {
            let ids = Array(shelf.cardIds.prefix(ShelfBuilder.maxCardsPerShelf))
            let store = self.store
            let loaded = await Task.detached(priority: .userInitiated) {
                let byId = Dictionary(uniqueKeysWithValues:
                    ((try? store.cards(ids: ids)) ?? []).map { ($0.id, $0) })
                let priced = (try? store.previewPrices(cardIds: ids)) ?? [:]
                return (ids.compactMap { byId[$0] }, priced)
            }.value
            cards = loaded.0
            prices = loaded.1
        }
    }
}
