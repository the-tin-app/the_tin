import SwiftUI

/// The Wanted screen: the sets you're collecting, and the singles you're hunting.
///
/// These are two different kinds of wanting and they used to share one bucket. A set is a goal
/// with a finish line whose missing cards are a consequence; a single is a card you chose, with a
/// target price and a priority. Bulk-hearting a set's gap drowned the second kind in the first.
struct WantedView: View {
    let store: CatalogStore
    let wants: WantsModel
    var collection: CollectionModel? = nil
    var goals: SetGoalsModel? = nil

    @AppStorage("wantedScope") private var scopeRaw: String = Scope.sets.rawValue

    enum Scope: String, CaseIterable {
        case sets, singles
        var label: String { self == .sets ? "Sets" : "Singles" }
    }

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .sets }

    var body: some View {
        Group {
            switch scope {
            case .sets:
                SetGoalsListView(store: store, goals: goals, collection: collection, wants: wants)
            case .singles:
                WantedCardsView(store: store, wants: wants, collection: collection, goals: goals)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Wanted", selection: $scopeRaw) {
                ForEach(Scope.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// The sets you're chasing, closest to done first.
struct SetGoalsListView: View {
    let store: CatalogStore
    var goals: SetGoalsModel?
    var collection: CollectionModel?
    var wants: WantsModel?

    private var ownedIds: Set<String> { Set((collection?.entries ?? []).map(\.cardId)) }

    /// Recomputed per body pass from the catalog. One `cards(inSet:)` + one price read per chased
    /// set — a handful of sets, not a scan of the catalog.
    private var progress: [SetGoalProgress] {
        let owned = ownedIds
        let rows = (goals?.setIds ?? []).compactMap { setId -> SetGoalProgress? in
            guard let set = try? store.set(id: setId) else { return nil }
            let cards = (try? store.cards(inSet: setId)) ?? []
            let prices = (try? store.previewPrices(cardIds: cards.map(\.id))) ?? [:]
            return SetGoals.progress(set: set, cards: cards, ownedCardIds: owned, prices: prices)
        }
        return SetGoals.sorted(rows)
    }

    var body: some View {
        let rows = progress
        List {
            ForEach(rows) { row in
                NavigationLink(value: SetID(raw: row.set.id)) {
                    SetGoalRow(progress: row)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No sets on the go", systemImage: "square.grid.2x2")
                } description: {
                    Text("Open a set and tap “Collect this set”. The Tin then tracks what's left for you — no need to wishlist them one by one.")
                }
            }
        }
        .navigationDestination(for: SetID.self) { setID in
            if let set = try? store.set(id: setID.raw) {
                SetDetailView(model: SetDetailModel(store: store, set: set, filter: .missing),
                              entries: collection?.entries ?? [], store: store,
                              collection: collection, wants: wants, goals: goals)
            }
        }
    }
}

/// One chased set: cover art, how far in you are, and what the rest costs.
private struct SetGoalRow: View {
    let progress: SetGoalProgress

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.set.name).font(.headline).lineLimit(1)
                ProgressView(value: Double(progress.owned), total: Double(max(progress.total, 1)))
                HStack(spacing: 6) {
                    Text("\(progress.owned)/\(progress.total)")
                        .monospacedDigit()
                    if progress.isComplete {
                        Text("· complete").foregroundStyle(.green)
                    } else {
                        Text("· ^[\(progress.remaining) card](inflect: true) left")
                        if progress.gapValue > 0 {
                            Text("· \(progress.gapValue, format: .currency(code: "USD").precision(.fractionLength(0)))")
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                // The gap price only covers cards the catalog prices; saying so stops the number
                // reading as the whole cost.
                if !progress.isComplete, progress.pricedMissing < progress.remaining {
                    Text("\(progress.pricedMissing) of \(progress.remaining) priced")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.isComplete
            ? "\(progress.set.name), complete"
            : "\(progress.set.name), \(progress.owned) of \(progress.total), \(progress.remaining) left")
    }
}
