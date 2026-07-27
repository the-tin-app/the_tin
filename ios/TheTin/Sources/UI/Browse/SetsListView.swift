import SwiftUI

struct SetsListView: View {
    let sets: [SetRecord]
    let store: CatalogStore
    var entries: [CollectionEntry] = []
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    /// Threaded down so a set screen can offer "Collect this set". Without it the button is
    /// invisible on the ONLY path most people take to a set (2026-07-25).
    var goals: SetGoalsModel? = nil

    @State private var model = SetsListModel()

    // `.top`: a LazyVGrid row is as tall as its tallest cell, so a two-line set name used to make
    // its neighbours ragged. Reserving a blank second line on EVERY cell fixed the raggedness by
    // making every short name pay for it — a permanent gap between the name and its count.
    // Top-aligning puts the slack at the bottom of the cell, where nothing is looking at it.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12, alignment: .top)]

    /// The catalog reads this screen needs, held across body passes.
    ///
    /// This one was missed when the other three screens were fixed, and it was the worst of them:
    /// `setRawTotals()` is a LEFT JOIN over every card and every price row with a GROUP BY, and it
    /// ran **synchronously on the main thread at the top of `body`, on every pass** — alongside a
    /// `cards(ids:)` for every card you own and a `card(id:)` per visible cell. Pushing onto this
    /// screen could stall the main thread long enough to look like a freeze (reported on device
    /// 2026-07-26, navigating quickly from Wanted → Sets into By Set).
    @State private var catalog = SetsCatalog()

    private func repCard(_ set: SetRecord) -> CardRecord? {
        set.repCardId.flatMap { catalog.card(id: $0, store: store) }
    }

    @ViewBuilder
    private func cell(_ set: SetRecord, ownedCounts: [String: Int]) -> some View {
        NavigationLink(value: SetID(raw: set.id)) {
            VStack(spacing: 4) {
                CardImageView(card: repCard(set), quality: "low")
                Text(set.name).font(.caption).lineLimit(2)
                    .multilineTextAlignment(.center)
                // Capped like GroupStats.setCompletion: secret rares push a set's card list past
                // its printed total, and "104/102 collected" reads as a bug.
                Text("\(min(ownedCounts[set.id] ?? 0, set.total))/\(set.total)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(_ section: SetSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if section.isFirstOfCategory {
                Text(section.category.rawValue).font(.title3.bold())
            }
            Text(section.year).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, section.isFirstOfCategory ? 8 : 0)
    }

    var body: some View {
        let rawTotals = catalog.rawTotals(store: store)
        let ownedCounts = catalog.ownedCounts(entries: entries, store: store)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SetsListModel.sections(sets: sets, rawTotals: rawTotals, ownedCounts: ownedCounts, by: model.sort)) { section in
                    Section {
                        ForEach(section.sets) { set in cell(set, ownedCounts: ownedCounts) }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Sets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(SetSort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .onChange(of: collection?.catalogGeneration) { catalog.clear() }
        .navigationDestination(for: SetID.self) { setID in
            if let set = try? store.set(id: setID.raw) {
                SetDetailView(model: SetDetailModel(store: store, set: set),
                              entries: entries, store: store, collection: collection,
                              wants: wants, goals: goals)
            }
        }
    }
}

/// Catalog reads for the sets grid, held across body passes.
///
/// Same reference-type-in-`@State` pattern as `CardSearchIndex`, `WishlistCatalog` and
/// `SetGoalCatalog`. Three different lifetimes, cached separately:
/// - `rawTotals` is a whole-catalog aggregate and only changes when the artifact does;
/// - `ownedCounts` changes when you acquire or sell a card, so it's keyed on the owned id set;
/// - `cards` are the per-cell cover lookups, one SQLite read each, ~40 visible at a time.
fileprivate final class SetsCatalog {
    private var totals: [String: Double]?
    private var ownedKey: Set<String>?
    private var counts: [String: Int] = [:]
    private var cards: [String: CardRecord?] = [:]

    func rawTotals(store: CatalogStore) -> [String: Double] {
        if let totals { return totals }
        let t = (try? store.setRawTotals()) ?? [:]
        totals = t
        return t
    }

    func ownedCounts(entries: [CollectionEntry], store: CatalogStore) -> [String: Int] {
        let ids = Set(entries.map(\.cardId))
        guard ownedKey != ids else { return counts }
        counts = SetsListModel.ownedCounts(ownedCards: (try? store.cards(ids: Array(ids))) ?? [])
        ownedKey = ids
        return counts
    }

    func card(id: String, store: CatalogStore) -> CardRecord? {
        if let cached = cards[id] { return cached }
        let record = try? store.card(id: id)
        cards[id] = record
        return record
    }

    func clear() {
        totals = nil
        ownedKey = nil
        counts = [:]
        cards = [:]
    }
}
