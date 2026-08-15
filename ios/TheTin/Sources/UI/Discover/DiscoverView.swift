import SwiftUI

struct DiscoverView: View {
    let store: CatalogStore
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    var goals: SetGoalsModel? = nil
    var signals: DiscoverSignalsModel? = nil
    @State private var model: DiscoverModel?
    /// The price picker, opened from a row on this screen. NOT presented automatically.
    ///
    /// Three placements now. As an `.interactiveDismissDisabled` sheet at launch it was the first
    /// screen of the app — a budget form before a single card. Moved to the For You shelves screen,
    /// it became **unreachable**: with no tiers, no owned cards and no wants, `ShelfBuilder` emits
    /// no shelves, `DiscoverHomeView` drops an empty row, and the "See all" that opens the shelves
    /// screen does not exist — so on a true first run there was no door to the question at all
    /// (found on the simulator, 2026-08-12; the earlier "it works" reading came from a rig whose
    /// tiers were already set). Discover's home is the one surface a new user is guaranteed to
    /// land on, so the offer lives here and opens on a tap.
    @State private var showSeed = false

    /// The answered price lines, held as real view state rather than read from `AppConfig` inside
    /// `body`.
    ///
    /// ⚠️ **`AppConfig.priceTiers` is UserDefaults, and SwiftUI cannot observe UserDefaults.** Read
    /// straight from `body`, answering the picker wrote the value and changed nothing on screen:
    /// the prompt row stayed, and For You never appeared, because nothing invalidated this view and
    /// so `inputs.recomputeKey` was never recalculated. Dismissing the sheet is not a reliable
    /// invalidation either — the binding is already `false` by the time `onDone` sets it. Assigning
    /// here is a state change SwiftUI is guaranteed to see, which re-renders AND re-keys `.task`.
    /// (Observed on the simulator, 2026-08-12: tiers written to the plist, screen unchanged.)
    @State private var tiers = AppConfig.priceTiers

    var body: some View {
        // One view, loaded or not. This used to be `Group { if isLoaded { home } else { TinLoadingView } }`,
        // which is two `_ConditionalContent` identities — so `isLoaded` flipping DESTROYED the layout and
        // rebuilt it, and the centred loading tin was replaced by a top-anchored scroll view. On an A10
        // iPad that reads as the whole screen popping to the top. The home renders its own skeletons now.
        DiscoverHomeView(model: model, store: store, collection: collection, wants: wants,
                         needsSeed: tiers == nil,
                         onTapSeed: { showSeed = true })
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
                // For You's "See all" opens the shelves screen, where the reason is the row header.
                // Full-art and Chase keep their existing decks.
                if route.kind == .forYou {
                    ForYouShelvesView(shelves: model.shelves, store: store,
                                      wants: wants, collection: collection)
                } else {
                    StreamView(title: route.kind.title,
                               stream: model.makeStream(route.kind),
                               caption: { model.caption(for: $0, kind: route.kind) },
                               store: store, wants: wants, collection: collection)
                }
            }
        }
        .navigationDestination(for: ShelfRoute.self) { route in
            if let model, let shelf = model.shelves.first(where: { $0.id == route.shelfId }) {
                // `signals:` only on For You surfaces — a thumbs-down on Full-art or Chase would
                // promise tuning that only the personalised ranker can deliver.
                StreamView(title: shelf.title,
                           stream: model.makeStream(for: shelf),
                           caption: { _ in shelf.caption },
                           store: store, wants: wants, collection: collection, signals: signals)
            }
        }
        // The whole browse surface (By Set / By Dex / Sealed / All Cards), not just the filter
        // deck — this row used to open a screen called "Browse" that had nothing in common with
        // the "Browse" tab.
        .navigationDestination(for: BrowseRoute.self) { _ in
            BrowseView(store: store, entries: collection?.entries ?? [],
                       collection: collection, wants: wants, goals: goals)
        }
        .task(id: inputs.recomputeKey) {
            let m = model ?? DiscoverModel(store: store)
            await m.load(inputs)
            model = m
        }
        .sheet(isPresented: $showSeed) { seedSheet }
        // Settings can edit the same value, and this view's `@State` copy would otherwise stay
        // stale until the app relaunched. Cheap: one UserDefaults read per appearance.
        .onAppear { tiers = AppConfig.priceTiers }
    }

    @ViewBuilder private var seedSheet: some View {
        ForYouSeedView(initial: tiers) {
            // Pull the saved value back into state — this assignment is what rebuilds Discover.
            tiers = AppConfig.priceTiers
            showSeed = false
        }
    }

    private var inputs: DiscoverModel.Inputs {
        .init(entries: collection?.entries ?? [],
              wants: wants?.entries ?? [:],
              setGoals: goals?.setIds ?? [],
              dismissed: signals?.dismissed ?? [],
              reasons: signals?.reasons ?? [:],
              at: signals?.at ?? [:],
              signalsRevision: signals?.revision ?? 0,
              tiers: tiers)
    }

}

private struct DiscoverHomeView: View {
    /// Nil until the first `load()` returns — the rows render skeletons in the meantime rather than
    /// the surface being swapped out for a spinner.
    let model: DiscoverModel?
    let store: CatalogStore
    var collection: CollectionModel?
    var wants: WantsModel?
    /// The price picker has never been answered.
    var needsSeed: Bool = false
    var onTapSeed: () -> Void = {}

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
                // Only until it's answered. Placed above the rows because on a first run it is
                // the one thing here that CHANGES what's below it — answering adds the three
                // price-banded For You rows, which without it don't exist to be discovered.
                if needsSeed { seedPrompt }
                ForEach(DiscoverModel.StreamKind.allCases, id: \.self) { kind in
                    let cards = model?.previews[kind] ?? []
                    // Every row is present while loading; only a row that is genuinely empty
                    // *after* loading is dropped.
                    if !isLoaded || !cards.isEmpty {
                        StreamPreviewRow(kind: kind, cards: cards, store: store,
                                         wants: wants, collection: collection)
                    }
                }
                if let model, !model.connections.isEmpty {
                    ConnectionsRow(connections: model.connections, store: store,
                                   wants: wants, collection: collection)
                }
            }
            .padding(.vertical)
        }
    }

    /// The price question as a row, shown until it's answered.
    ///
    /// Not a modal. It was one at launch, and being the first screen of the app is exactly what
    /// this whole change set removed. A row states the offer and costs a new user nothing to
    /// ignore — and unlike the sheet, ignoring it doesn't count as answering: Skip stores the
    /// defaults and never asks again, whereas this stays put until someone actually decides.
    private var seedPrompt: some View {
        Button(action: onTapSeed) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tune Discover to your budget")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Two questions about price, and you get rows you'd actually buy from.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}

/// A stream's home row: title header with a "See all ›" link, then the horizontal tile strip.
private struct StreamPreviewRow: View {
    let kind: DiscoverModel.StreamKind
    let cards: [CardRecord]
    let store: CatalogStore
    var wants: WantsModel?
    var collection: CollectionModel?

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
                                     collection: collection, store: store)
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
struct SkeletonTile: View {
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
                                                 collection: collection, store: store)
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

struct DiscoverTile: View {
    let card: CardRecord
    let value: Double?
    var wants: WantsModel?
    var collection: CollectionModel?
    var store: CatalogStore?

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
        .cardQuickActions(card: card, wants: wants, collection: collection, store: store)
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
