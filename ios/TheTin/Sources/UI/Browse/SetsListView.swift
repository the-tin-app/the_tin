import SwiftUI

struct SetsListView: View {
    let sets: [SetRecord]
    let store: CatalogStore
    var entries: [CollectionEntry] = []
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil

    @State private var model = SetsListModel()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    private var rawTotals: [String: Double] { (try? store.setRawTotals()) ?? [:] }

    private var ownedCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let cardId = entry.cardId
            guard let dash = cardId.lastIndex(of: "-") else { continue }
            let setId = String(cardId[..<dash])
            counts[setId, default: 0] += 1
        }
        return counts
    }

    private func repCard(_ set: SetRecord) -> CardRecord? {
        set.repCardId.flatMap { try? store.card(id: $0) }
    }

    @ViewBuilder
    private func cell(_ set: SetRecord, ownedCounts: [String: Int]) -> some View {
        NavigationLink(value: SetID(raw: set.id)) {
            VStack(spacing: 4) {
                CardImageView(card: repCard(set), quality: "low")
                Text(set.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                Text("\(ownedCounts[set.id] ?? 0)/\(set.total)").font(.caption2).foregroundStyle(.secondary)
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
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .navigationDestination(for: SetID.self) { setID in
            if let set = try? store.set(id: setID.raw) {
                SetDetailView(model: SetDetailModel(store: store, set: set),
                              entries: entries, store: store, collection: collection, wants: wants)
            }
        }
    }
}
