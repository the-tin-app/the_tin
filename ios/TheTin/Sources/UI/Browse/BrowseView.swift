import SwiftUI

enum BrowseAxis: String, CaseIterable, Identifiable {
    case set, pokedex, sealed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .set: return "By Set"
        case .pokedex: return "By Pokédex"
        case .sealed: return "Sealed"
        }
    }
}

struct BrowseView: View {
    let store: CatalogStore
    var entries: [CollectionEntry] = []
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    @State private var axis: BrowseAxis = .set

    var body: some View {
        Group {
            switch axis {
            case .set:
                SetsListView(sets: (try? store.sets()) ?? [], store: store,
                             entries: entries, collection: collection, wants: wants)
            case .pokedex:
                PokedexListView(store: store, entries: entries, collection: collection, wants: wants)
            case .sealed:
                SealedListView(store: store)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Browse by", selection: $axis) {
                ForEach(BrowseAxis.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
        }
    }
}
