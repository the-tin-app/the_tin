import SwiftUI

enum BrowseAxis: String, CaseIterable, Identifiable {
    case set, pokedex, sealed, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .set: return "By Set"
        case .pokedex: return "By Dex"
        case .sealed: return "Sealed"
        case .all: return "All Cards"
        }
    }
}

/// The one place the catalog is browsed. Four ways to slice it — by set, by species, sealed
/// products, or every card with filters on top.
///
/// It used to be two screens: this one behind its own tab, and a *separate* filterable deck behind
/// Discover's "Browse & filter" row. Two doors, different contents, same catalog — so "Browse"
/// meant one thing in the tab bar and another on Discover. The deck is now the fourth segment
/// here, and Discover's row leads to this screen (2026-07-24).
struct BrowseView: View {
    let store: CatalogStore
    var entries: [CollectionEntry] = []
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    var goals: SetGoalsModel? = nil
    @State private var axis: BrowseAxis = .set

    var body: some View {
        Group {
            switch axis {
            case .set:
                SetsListView(sets: (try? store.sets()) ?? [], store: store,
                             entries: entries, collection: collection, wants: wants, goals: goals)
            case .pokedex:
                PokedexListView(store: store, entries: entries, collection: collection, wants: wants)
            case .sealed:
                SealedListView(store: store)
            case .all:
                DiscoverBrowseView(store: store, collection: collection, wants: wants)
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
