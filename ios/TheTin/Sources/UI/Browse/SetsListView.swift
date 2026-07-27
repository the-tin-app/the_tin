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

    private var rawTotals: [String: Double] { (try? store.setRawTotals()) ?? [:] }

    private var ownedCounts: [String: Int] {
        let ids = Array(Set(entries.map(\.cardId)))
        return SetsListModel.ownedCounts(ownedCards: (try? store.cards(ids: ids)) ?? [])
    }

    private func repCard(_ set: SetRecord) -> CardRecord? {
        set.repCardId.flatMap { try? store.card(id: $0) }
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
        let rawTotals = rawTotals
        let ownedCounts = ownedCounts
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
        .navigationDestination(for: SetID.self) { setID in
            if let set = try? store.set(id: setID.raw) {
                SetDetailView(model: SetDetailModel(store: store, set: set),
                              entries: entries, store: store, collection: collection,
                              wants: wants, goals: goals)
            }
        }
    }
}
