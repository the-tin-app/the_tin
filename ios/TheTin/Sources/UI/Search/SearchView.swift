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

    var body: some View {
        List(model.results) { card in
            NavigationLink(value: CardID(raw: card.id)) {
                HStack(spacing: 12) {
                    CardImageView(card: card, quality: "low").frame(width: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name).lineLimit(1)
                        Text(model.caption(for: card))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let hp = card.hp {
                            Text("HP \(hp)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    PriceLabel(value: model.prices[card.id]?.rawUsd)
                }
            }
        }
        .overlay {
            if model.results.isEmpty {
                ContentUnavailableView(
                    model.text.isEmpty ? "Search the catalog" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(#"Try a name, a move like slash, hp:120, 58/112, or a "quoted card text" phrase — works fully offline."#))
            }
        }
        .searchable(text: $model.text, prompt: "Name, move, hp:…, 58/112")
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: history ?? CatalogPriceHistory(store: store)),
                               store: store, collection: collection, wants: wants)
            }
        }
    }
}
