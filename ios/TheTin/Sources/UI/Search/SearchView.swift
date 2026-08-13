import SwiftUI
import Observation

/// Offline FTS5 search UI (spec §5.1): fully local → instant, no network needed.
@MainActor @Observable
final class SearchModel {
    private let store: CatalogStore
    private(set) var results: [CardRecord] = []
    private(set) var prices: [String: PriceRecord] = [:]
    /// setId → "Set name · 2016". Loaded once (a few hundred rows) so every result row can say
    /// which set it's from — without it a search for "Charizard" is sixty identical-looking rows.
    private var setCaptions: [String: String] = [:]

    var text: String = "" {
        didSet { run() }
    }

    init(store: CatalogStore) {
        self.store = store
        let sets: [SetRecord] = (try? store.sets()) ?? []
        for set in sets {
            let date: String = set.releaseDate ?? ""
            let year: String = date.count >= 4 ? String(date.prefix(4)) : ""
            setCaptions[set.id] = year.isEmpty ? set.name : set.name + " · " + year
        }
    }

    /// "Base Set · 1999 · #4" — set first: it's what tells two same-named cards apart.
    func caption(for card: CardRecord) -> String {
        let number = "#\(card.number)"
        guard let set = setCaptions[card.setId] else { return number }
        return "\(set) · \(number)"
    }

    private func run() {
        let query = SearchQuery.parse(text)
        guard !query.isEmpty else {
            results = []
            prices = [:]
            return
        }
        results = (try? store.search(query)) ?? []
        prices = (try? store.prices(cardIds: results.map(\.id))) ?? [:]
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    let store: CatalogStore
    var history: PriceHistoryProviding? = nil
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil

    /// Cards opened recently, resolved once per appearance. `AppConfig.recentCardIds` is a plain
    /// UserDefaults array, so this is where it becomes catalog rows.
    @State private var recents: [CardRecord] = []

    /// Recents earn the screen only when there is no query to answer.
    private var showsRecents: Bool { model.text.isEmpty && !recents.isEmpty }

    var body: some View {
        // Hoisted out of the row: built per row it would be an O(entries) map and Set build for
        // every visible cell, on a screen that re-renders per keystroke.
        let owned = Set((collection?.entries ?? []).map(\.cardId))
        List {
            if showsRecents {
                Section("Recently viewed") {
                    ForEach(recents) { card in
                        row(card, owned: owned, price: nil)
                    }
                }
            }
            ForEach(model.results) { card in
                row(card, owned: owned, price: model.prices[card.id]?.rawUsd)
            }
        }
        .overlay {
            // Not while recents are showing — the whole point is that the landing has something
            // on it, and an overlay would cover what it just gained.
            if model.results.isEmpty, !showsRecents {
                ContentUnavailableView(
                    model.text.isEmpty ? "Search the catalog" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(#"Try a name, a move like slash, hp:120, 58/112, or a "quoted card text" phrase — works fully offline."#))
            }
        }
        .searchable(text: $model.text, prompt: "Name, move, hp:…, 58/112")
        .task { recents = orderedRecents() }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: history ?? CatalogPriceHistory(store: store)),
                               store: store, collection: collection, wants: wants)
            }
        }
    }

    /// One result. Shared by the results list and the recents section so the two can never drift
    /// into looking like different kinds of thing — they are the same card, found two ways.
    ///
    /// `price` is passed in rather than read from `model.prices`: that dictionary only covers the
    /// current query's results, and a recents row would silently show no price at all.
    private func row(_ card: CardRecord, owned: Set<String>, price: Double?) -> some View {
        NavigationLink(value: CardID(raw: card.id)) {
            HStack(spacing: 12) {
                CardImageView(card: card, quality: "low").frame(width: 44)
                    // Search was the ONE card surface in the app without these — the set grids,
                    // Discover tiles, Movers rows, the scan tray and the wishlist all badge
                    // ownership, and the screen built for "do I already own this?" made you tap
                    // through to find out. Same 44pt thumbnail and 0.85 scale as `MarketMoverRow`,
                    // the precedent for this row size.
                    .overlay(alignment: .topTrailing) {
                        let wanted = wants?.isWanted(card.id) ?? false
                        if owned.contains(card.id) || wanted {
                            CardBadges(owned: owned.contains(card.id), wanted: wanted)
                                .scaleEffect(0.85)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name).lineLimit(1)
                    Text(model.caption(for: card))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let hp = card.hp {
                        Text("HP \(hp)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                PriceLabel(value: price)
            }
        }
    }

    /// Recents in the order they were viewed. `cards(ids:)` answers a SET — it neither preserves
    /// the id order nor returns a row for an id the catalog has since dropped — so the list is
    /// rebuilt from the id order and anything missing simply falls out.
    private func orderedRecents() -> [CardRecord] {
        let ids = AppConfig.recentCardIds
        guard !ids.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues:
            ((try? store.cards(ids: ids)) ?? []).map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }
}
