import SwiftUI
import Observation

@MainActor @Observable
final class SetDetailModel {
    let set: SetRecord
    private(set) var cards: [CardRecord] = []
    private(set) var prices: [String: PriceRecord] = [:]
    private(set) var rawTotal: Double = 0
    private(set) var asOf: String?
    private(set) var sealed: [SealedProduct] = []
    var sort: CardSort = .number
    var filter: CardFilter = .all

    init(store: CatalogStore, set: SetRecord) {
        self.set = set
        // Local SQLite reads are instant and cannot meaningfully fail after install;
        // an empty screen with the set header is the degraded state.
        cards = (try? store.cards(inSet: set.id)) ?? []
        prices = (try? store.prices(cardIds: cards.map(\.id))) ?? [:]
        rawTotal = (try? store.setRawTotal(setId: set.id)) ?? 0
        asOf = prices.values.map(\.asOf).max()
        sealed = (try? store.sealedProducts(setId: set.id)) ?? []
    }

    func completion(entries: [CollectionEntry]) -> (owned: Int, total: Int) {
        GroupStats.setCompletion(entries: entries, setCards: cards, setTotal: set.total)
    }

    func displayed(owned: Set<String>, wanted: Set<String>) -> [CardRecord] {
        // compactMapValues (not mapValues { ?? 0 }): a price row with null raw_usd
        // (EUR/graded only) must be treated as no-price so it sorts to the END, not as $0.
        CardGridSort.apply(cards: cards, prices: prices.compactMapValues(\.rawUsd), owned: owned, wanted: wanted,
                            setDates: [set.id: set.releaseDate ?? ""], sort: sort, filter: filter)
    }
}

struct SetDetailView: View {
    let model: SetDetailModel
    var entries: [CollectionEntry] = []
    let store: CatalogStore
    var history: PriceHistoryProviding? = nil
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
    private static let sortOptions: [CardSort] = [.number, .alphabetical, .cheapest, .expensive]

    private var owned: Set<String> { Set(entries.map(\.cardId)) }
    private var wanted: Set<String> { wants?.wanted ?? [] }

    var body: some View {
        let owned = owned
        let wanted = wanted
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let completion = model.completion(entries: entries)
                Text("\(completion.owned)/\(completion.total) collected")
                    .font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(completion.owned), total: Double(max(completion.total, 1)))
                HStack {
                    Text("Set raw value: \(model.rawTotal, format: .currency(code: "USD"))")
                    if let asOf = model.asOf { AsOfLabel(date: asOf) }
                }
                .font(.footnote)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.displayed(owned: owned, wanted: wanted)) { card in
                        NavigationLink(value: CardID(raw: card.id)) {
                            VStack(spacing: 4) {
                                CardImageView(card: card, quality: "low")
                                    .overlay(alignment: .topTrailing) {
                                        CardBadges(owned: owned.contains(card.id), wanted: wanted.contains(card.id))
                                    }
                                Text(card.name).font(.caption).lineLimit(1)
                                PriceLabel(value: model.prices[card.id]?.rawUsd)
                            }
                        }
                        .buttonStyle(.plain)
                        .cardQuickActions(cardId: card.id, wants: wants)
                    }
                }

                if !model.sealed.isEmpty {
                    Divider().padding(.vertical, 6)
                    Text("Sealed products").font(.headline)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.sealed) { SealedCard(product: $0) }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(model.set.name)
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
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
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
