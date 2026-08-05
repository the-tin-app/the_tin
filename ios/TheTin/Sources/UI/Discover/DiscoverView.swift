import SwiftUI

struct DiscoverView: View {
    let store: CatalogStore
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    var goals: SetGoalsModel? = nil
    var signals: DiscoverSignalsModel? = nil
    @State private var model: DiscoverModel?

    var body: some View {
        // One view, loaded or not. This used to be `Group { if isLoaded { home } else { TinLoadingView } }`,
        // which is two `_ConditionalContent` identities — so `isLoaded` flipping DESTROYED the layout and
        // rebuilt it, and the centred loading tin was replaced by a top-anchored scroll view. On an A10
        // iPad that reads as the whole screen popping to the top. The home renders its own skeletons now.
        DiscoverHomeView(model: model, store: store, collection: collection, wants: wants,
                         signals: signals)
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
    /// Nil until the first `load()` returns — the rows render skeletons in the meantime rather than
    /// the surface being swapped out for a spinner.
    let model: DiscoverModel?
    let store: CatalogStore
    var collection: CollectionModel?
    var wants: WantsModel?
    var signals: DiscoverSignalsModel?

    private var isLoaded: Bool { model?.isLoaded ?? false }

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
                    let cards = model?.previews[kind] ?? []
                    // Every row is present while loading; only a row that is genuinely empty
                    // *after* loading is dropped.
                    if !isLoaded || !cards.isEmpty {
                        StreamPreviewRow(kind: kind, cards: cards, store: store,
                                         wants: wants, collection: collection, signals: signals)
                    }
                }
                if let model, !model.connections.isEmpty {
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
        let prices = cards.isEmpty ? [:] : (try? store.previewPrices(cardIds: cards.map(\.id))) ?? [:]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title).font(.title3.bold())
                Spacer()
                // Kept (not hidden) while loading so the header doesn't reflow when cards land;
                // there is no stream to push until the model exists.
                NavigationLink(value: StreamRoute(kind: kind)) {
                    Text("See all ›").font(.subheadline)
                }
                .disabled(cards.isEmpty)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if cards.isEmpty {
                        // Enough to fill the widest phone; the strip scrolls, so more is wasted work.
                        ForEach(0..<4, id: \.self) { _ in SkeletonTile() }
                    }
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

/// A `DiscoverTile` with the data taken out: same metrics, so nothing moves when the real tile
/// replaces it. Built from the real `Text`/`PriceLabel` under `.redacted` rather than hand-sized
/// bars, which is how the line heights stay exact for free.
private struct SkeletonTile: View {
    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 110, height: 110 / 0.717) // the card ratio CardImageView applies
            Text("Card name").font(.caption).lineLimit(1)
            PriceLabel(value: 0) // a *priced* label — `nil` renders "no data" in the lighter caption
        }
        .frame(width: 120)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
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
                    // The panel sits ON the card, sized to it — not a screen of its own.
                    .overlay {
                        if askingWhy {
                            DismissReasonOverlay(compact: true) { reason in
                                signals?.dismiss(card.id, reason: reason)
                                askingWhy = false
                            } onCancel: { askingWhy = false }
                        } else if let signals, signals.isDismissed(card.id) {
                            // The card holds its slot wearing this, so the thumbs-down is visibly
                            // captured instead of the tile vanishing from under your finger.
                            DismissConfirmedOverlay(compact: true, reason: signals.reasons[card.id]) {
                                signals.restore(card.id)
                            }
                        }
                    }
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
        // Badges hide while the panel is open — they sit above it and were clipping its
        // top row of labels.
        .overlay(alignment: .topLeading) {
            if let signals, !askingWhy, !signals.isDismissed(card.id) {
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

        .overlay(alignment: .topTrailing) {
            if let wants, !askingWhy, !(signals?.isDismissed(card.id) ?? false) {
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
