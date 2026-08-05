import SwiftUI

struct DiscoverView: View {
    let store: CatalogStore
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    var goals: SetGoalsModel? = nil
    var signals: DiscoverSignalsModel? = nil
    @State private var model: DiscoverModel?

    var body: some View {
        Group {
            if let model, model.isLoaded {
                DiscoverHomeView(model: model, store: store, collection: collection, wants: wants,
                                 signals: signals)
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
                StreamView(title: route.kind.title,
                           stream: model.makeStream(route.kind),
                           caption: { model.caption(for: $0, kind: route.kind) },
                           store: store, wants: wants, signals: signals, collection: collection)
            }
        }
        // The whole browse surface (By Set / By Dex / Sealed / All Cards), not just the filter
        // deck — this row used to open a screen called "Browse" that had nothing in common with
        // the "Browse" tab.
        .navigationDestination(for: BrowseRoute.self) { _ in
            BrowseView(store: store, entries: collection?.entries ?? [],
                       collection: collection, wants: wants, goals: goals)
        }
        .task(id: tasteSignalKey) {
            let m = model ?? DiscoverModel(store: store)
            await m.load(entries: collection?.entries ?? [], wants: wants?.entries ?? [:],
                         dismissed: signals?.dismissed ?? [], reasons: signals?.reasons ?? [:])
            model = m
        }
    }

    /// ⚠️ `signals.revision` is load-bearing, not decoration. Counting owned and wanted cards
    /// cannot see a thumbs-down — it changes neither count — so without the revision the task
    /// never re-fires and "Not for me" appears to do nothing until you happen to heart something.
    private var tasteSignalKey: String {
        "\(collection?.entries.count ?? 0)-\(wants?.wanted.count ?? 0)-\(signals?.revision ?? 0)"
    }
}

private struct DiscoverHomeView: View {
    let model: DiscoverModel
    let store: CatalogStore
    var collection: CollectionModel?
    var wants: WantsModel?
    var signals: DiscoverSignalsModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NavigationLink(value: BrowseRoute()) {
                    HStack {
                        // Not a magnifying glass — that's Search's icon, and this row leading
                        // with it was half the reason Browse and Search read as the same door.
                        Label("Browse the catalog", systemImage: "square.grid.2x2")
                            .font(.title3.bold())
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                ForEach(DiscoverModel.StreamKind.allCases, id: \.self) { kind in
                    let cards = model.previews[kind] ?? []
                    if !cards.isEmpty {
                        StreamPreviewRow(kind: kind, cards: cards, store: store,
                                         wants: wants, collection: collection, signals: signals)
                    }
                }
                if !model.connections.isEmpty {
                    ConnectionsRow(connections: model.connections, store: store,
                                   wants: wants, collection: collection, signals: signals)
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
    var collection: CollectionModel?
    var signals: DiscoverSignalsModel?

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
                        DiscoverTile(card: card, value: prices[card.id], wants: wants,
                                     collection: collection, store: store, signals: signals)
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
    var collection: CollectionModel?
    var signals: DiscoverSignalsModel?

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
                                    DiscoverTile(card: card, value: prices[card.id], wants: wants,
                                                 collection: collection, store: store, signals: signals)
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
    var collection: CollectionModel?
    var store: CatalogStore?
    var signals: DiscoverSignalsModel?
    @State private var askingWhy = false

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
        .cardQuickActions(card: card, wants: wants, collection: collection, store: store,
                          signals: signals)
        // Mirrors the heart: Want on the right, Not-for-me on the left. The long-press menu still
        // carries both, but a menu item is not an affordance — it can't be seen.
        .overlay(alignment: .topLeading) {
            if signals != nil {
                Button {
                    askingWhy = true
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Not for me")
            }
        }
        .fullScreenCover(isPresented: $askingWhy) {
            DismissReasonOverlay(card: card) { reason in
                signals?.dismiss(card.id, reason: reason)
                askingWhy = false
            } onCancel: { askingWhy = false }
        }
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
