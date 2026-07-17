import SwiftUI

struct PokedexListView: View {
    let store: CatalogStore
    var entries: [CollectionEntry] = []
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil

    // Loaded once in init — local SQLite reads are instant, so no async needed;
    // avoids a flash of empty state before a `.task` could fire.
    @State private var pokemon: [PokemonRecord]
    // App-side rep override: highest-raw priced card (with image) per dex. Fixes species whose
    // baked rep_card_id is an unpriced card — shows a priced photo and its price instead.
    @State private var reps: [Int: (cardId: String, usd: Double)]
    @State private var sort: PokemonSort = .dex
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    init(store: CatalogStore, entries: [CollectionEntry] = [], collection: CollectionModel? = nil, wants: WantsModel? = nil) {
        self.store = store
        self.entries = entries
        self.collection = collection
        self.wants = wants
        _pokemon = State(initialValue: (try? store.pokemon()) ?? [])
        _reps = State(initialValue: (try? store.repByDex()) ?? [:])
    }

    // .mostOwned needs owned counts keyed by dexId. A card can map to more than one
    // species (card_dex is many-to-many), so this is built from a single batched
    // lookup rather than a per-row join — kept out of the per-row body to stay fast
    // for ~1000 species.
    private var ownedCounts: [Int: Int] {
        let dexMap = (try? store.dexIds(forCards: entries.map(\.cardId))) ?? [:]
        var counts: [Int: Int] = [:]
        for entry in entries {
            for dex in dexMap[entry.cardId] ?? [] {
                counts[dex, default: 0] += 1
            }
        }
        return counts
    }

    private func repCard(_ mon: PokemonRecord) -> CardRecord? {
        // Prefer the priced override; fall back to the baked rep. Some species have neither.
        let id = reps[mon.dexId]?.cardId ?? mon.repCardId
        return id.flatMap { try? store.card(id: $0) }
    }

    // Name filter for the search bar; empty query shows everything. Case/diacritic-insensitive
    // so "nidoran" matches "Nidoran♀". Filters the in-memory array — no data-layer work.
    private var filtered: [PokemonRecord] {
        guard !query.isEmpty else { return pokemon }
        return pokemon.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let ownedCounts = ownedCounts
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PokedexSort.sorted(pokemon: filtered, ownedCounts: ownedCounts, by: sort)) { mon in
                    NavigationLink(value: DexID(raw: mon.dexId)) {
                        VStack(spacing: 4) {
                            CardImageView(card: repCard(mon), quality: "low")
                            Text(mon.name).font(.caption).lineLimit(1)
                            Text("#\(mon.dexId)").font(.caption2).foregroundStyle(.secondary)
                            if let price = reps[mon.dexId]?.usd {
                                Text(price, format: .currency(code: "USD")).font(.caption2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Pokédex")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search Pokémon")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(PokemonSort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .navigationDestination(for: DexID.self) { dexID in
            if let mon = pokemon.first(where: { $0.dexId == dexID.raw }) {
                PokemonDetailView(model: PokemonDetailModel(store: store, mon: mon),
                                  entries: entries, store: store, collection: collection, wants: wants)
            }
        }
    }
}
