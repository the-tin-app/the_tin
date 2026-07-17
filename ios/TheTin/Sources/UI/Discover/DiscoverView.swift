import SwiftUI

struct DiscoverView: View {
    let store: CatalogStore
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    @State private var model: DiscoverModel?

    var body: some View {
        Group {
            if let model, model.isLoaded {
                DiscoverHomeView(model: model, store: store, collection: collection, wants: wants)
            } else {
                TinLoadingView(label: "Finding cards for you…")
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: CatalogPriceHistory(store: store)),
                               store: store, collection: collection, wants: wants)
            }
        }
        .navigationDestination(for: StreamRoute.self) { route in
            if let model {
                StreamView(kind: route.kind, model: model, wants: wants, collection: collection)
            }
        }
        .task(id: tasteSignalKey) {
            let m = model ?? DiscoverModel(store: store)
            await m.load(ownedIds: (collection?.entries ?? []).map(\.cardId), wantedIds: wants?.wanted ?? [])
            model = m
        }
    }

    private var tasteSignalKey: String {
        "\(collection?.entries.count ?? 0)-\(wants?.wanted.count ?? 0)"
    }
}

private struct DiscoverHomeView: View {
    let model: DiscoverModel
    let store: CatalogStore
    var collection: CollectionModel?
    var wants: WantsModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(DiscoverModel.StreamKind.allCases, id: \.self) { kind in
                    let cards = model.previews[kind] ?? []
                    if !cards.isEmpty {
                        StreamPreviewRow(kind: kind, cards: cards, store: store, wants: wants)
                    }
                }
                if !model.connections.isEmpty {
                    ConnectionsRow(connections: model.connections, store: store, wants: wants)
                }
            }
            .padding(.vertical)
        }
    }
}

/// A stream's home row: title header with a "See all ›" link, then the horizontal tile strip.
private struct StreamPreviewRow: View {
    let kind: DiscoverModel.StreamKind
    let cards: [CardRecord]
    let store: CatalogStore
    var wants: WantsModel?

    var body: some View {
        // Preview price = raw market, falling back to the NM condition price (a separate feed)
        // when raw is absent. Batched once per row rather than one query per tile.
        let prices = (try? store.previewPrices(cardIds: cards.map(\.id))) ?? [:]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title).font(.title3.bold())
                Spacer()
                NavigationLink(value: StreamRoute(kind: kind)) {
                    Text("See all ›").font(.subheadline)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        DiscoverTile(card: card, value: prices[card.id], wants: wants)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Curated + auto-derived connections, each a titled cluster of its `cardIds`.
private struct ConnectionsRow: View {
    let connections: [Connection]
    let store: CatalogStore
    var wants: WantsModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connections").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(connections) { connection in
                        let cards = (try? store.cards(ids: connection.cardIds)) ?? []
                        let prices = (try? store.previewPrices(cardIds: cards.map(\.id))) ?? [:]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(connection.title).font(.caption.bold()).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(cards) { card in
                                    DiscoverTile(card: card, value: prices[card.id], wants: wants)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct DiscoverTile: View {
    let card: CardRecord
    let value: Double?
    var wants: WantsModel?

    var body: some View {
        NavigationLink(value: CardID(raw: card.id)) {
            VStack(spacing: 4) {
                CardImageView(card: card, quality: "low")
                    .frame(width: 110)
                Text(card.name).font(.caption).lineLimit(1)
                PriceLabel(value: value)
            }
            .frame(width: 120)
        }
        .buttonStyle(.plain)
        .cardQuickActions(cardId: card.id, wants: wants)
        .overlay(alignment: .topTrailing) {
            if let wants {
                Button {
                    wants.toggle(card.id)
                } label: {
                    Image(systemName: wants.isWanted(card.id) ? "heart.fill" : "heart")
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                        // Visual stays a small badge; the hit target meets the 44 pt floor.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(wants.isWanted(card.id) ? "Remove from wishlist" : "Add to wishlist")
            }
        }
    }
}
