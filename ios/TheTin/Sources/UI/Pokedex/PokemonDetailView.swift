import SwiftUI
import Observation

@MainActor @Observable
final class PokemonDetailModel {
    let mon: PokemonRecord
    private(set) var cards: [CardRecord] = []
    private(set) var prices: [String: PriceRecord] = [:]
    // Preview price per card: raw_usd, else the NM/best condition price (raw is often null while a
    // condition price exists). Used for both the shown price and the sort so they agree.
    private(set) var previewUsd: [String: Double] = [:]
    private(set) var setNames: [String: String] = [:]
    private(set) var setDates: [String: String] = [:]
    var sort: CardSort = .number
    var filter: CardFilter = .all

    init(store: CatalogStore, mon: PokemonRecord) {
        self.mon = mon
        // Local SQLite reads are instant and cannot meaningfully fail after install;
        // an empty screen with the species header is the degraded state.
        cards = (try? store.cards(forDex: mon.dexId)) ?? []
        prices = (try? store.prices(cardIds: cards.map(\.id))) ?? [:]
        previewUsd = (try? store.previewPrices(cardIds: cards.map(\.id))) ?? [:]
        let sets = (try? store.sets()) ?? []
        setNames = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.name) })
        setDates = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.releaseDate ?? "") })
    }

    func displayed(owned: Set<String>, wanted: Set<String>) -> [CardRecord] {
        // Use the preview price (raw or NM/condition fallback); cards with truly no price are
        // absent from the map and sort to the END, not as $0.
        CardGridSort.apply(cards: cards, prices: previewUsd, owned: owned, wanted: wanted,
                            setDates: setDates, sort: sort, filter: filter)
    }
}

struct PokemonDetailView: View {
    let model: PokemonDetailModel
    var entries: [CollectionEntry] = []
    let store: CatalogStore
    var history: PriceHistoryProviding? = nil
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
    private static let sortOptions = CardSort.allCases

    private var owned: Set<String> { Set(entries.map(\.cardId)) }
    private var wanted: Set<String> { wants?.wanted ?? [] }

    var body: some View {
        let owned = owned
        let wanted = wanted
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.displayed(owned: owned, wanted: wanted)) { card in
                    NavigationLink(value: CardID(raw: card.id)) {
                        VStack(spacing: 4) {
                            CardImageView(card: card, quality: "low")
                                .overlay(alignment: .topTrailing) {
                                    CardBadges(owned: owned.contains(card.id), wanted: wanted.contains(card.id))
                                }
                            Text(card.name).font(.caption).lineLimit(1)
                            Text(model.setNames[card.setId] ?? card.setId)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            // Always render a price line so unpriced cards keep the same cell
                            // height as priced ones (otherwise the grid rows go ragged).
                            if let usd = model.previewUsd[card.id] {
                                Text(usd, format: .currency(code: "USD")).font(.caption2)
                            } else {
                                Text("No price available").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(model.mon.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: Bindable(model).sort) {
                        ForEach(Self.sortOptions) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Filter", selection: Bindable(model).filter) {
                        ForEach(CardFilter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: history ?? CatalogPriceHistory(store: store)),
                               store: store, collection: collection, wants: wants)
            }
        }
    }
}
