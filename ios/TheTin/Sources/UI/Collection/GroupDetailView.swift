import SwiftUI

struct GroupDetailView: View {
    @Bindable var model: CollectionModel
    let group: CardGroup
    let store: CatalogStore
    @State private var sortByValue = false
    @State private var editingEntry: CollectionEntry?
    @State private var printRequest: PrintSheetRequest?
    @State private var deletingEntry: CollectionEntry?

    var body: some View {
        List {
            Section {
                let value = model.groupValue(group.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.total, format: .currency(code: "USD")).font(.title2.bold())
                    Text("Priced \(value.pricedEntries) of \(value.totalEntries) entries")
                        .font(.caption).foregroundStyle(.secondary)
                    if let asOf = try? store.priceAsOf() { AsOfLabel(date: asOf) }
                }
            }
            Section {
                ForEach(model.sortedEntries(in: group.id, byValue: sortByValue)) { entry in
                    Button { editingEntry = entry } label: { entryRow(entry) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { deletingEntry = entry }
                        }
                }
            }
        }
        .navigationTitle(group.name)
        .toolbar {
            Toggle("Sort by value", isOn: $sortByValue)
            Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                label: { Label("Print sheet…", systemImage: "printer") }
                .disabled(model.entries(in: group.id).isEmpty)
        }
        .printSheetFlow($printRequest)
        .confirmationDialog(
            "Remove \((try? store.card(id: deletingEntry?.cardId ?? ""))?.name ?? "this card") from your tin?",
            isPresented: Binding(get: { deletingEntry != nil },
                                 set: { if !$0 { deletingEntry = nil } }),
            titleVisibility: .visible,
            presenting: deletingEntry
        ) { entry in
            Button("Remove", role: .destructive) { Task { await model.deleteEntry(id: entry.id) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editingEntry) { entry in
            if let card = try? store.card(id: entry.cardId) {
                NavigationStack {
                    EntryFormView(card: card, groups: model.groups, existing: entry) { updated in
                        await model.saveEntry(updated)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: CollectionEntry) -> some View {
        HStack(spacing: 12) {
            if let card = try? store.card(id: entry.cardId) {
                CardImageView(card: card, quality: "low").frame(width: 44)
                VStack(alignment: .leading) {
                    Text(card.name)
                    Text("×\(entry.qty)\(entry.variantValue.map { " · \($0.label)" } ?? "")\(entry.condition.map { " · \($0)" } ?? "")\(entry.gradeValue.map { " · \($0.label)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let from = entry.acquiredFrom, !from.isEmpty {
                        Text("from \(from)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                PriceLabel(value: GroupStats.entryValue(entry, price: model.prices[entry.cardId],
                                                        variants: model.variantsByCard[entry.cardId] ?? [],
                                                        conditions: model.conditionsByCard[entry.cardId] ?? []))
            } else {
                Text(entry.cardId).font(.caption.monospaced())
            }
        }
    }
}
