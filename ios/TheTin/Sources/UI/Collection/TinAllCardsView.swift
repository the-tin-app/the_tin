import SwiftUI

/// The whole owned collection ("The Tin") — every card across all groups plus ungrouped
/// (freshly committed-to-Tin) cards, so nothing routed to the Tin is invisible.
struct TinAllCardsView: View {
    let model: CollectionModel
    let store: CatalogStore

    /// Owned cards that live in a real group (ungrouped ones surface in the "Unfiled" section),
    /// so every card appears exactly once across the two sections.
    private var groupedEntries: [CollectionEntry] {
        model.allOwnedEntries.filter { !$0.groupId.isEmpty }
    }

    var body: some View {
        List {
            if !model.ungroupedEntries.isEmpty {
                Section("Unfiled") {
                    ForEach(model.ungroupedEntries) { entry in row(entry) }
                }
            }
            if !groupedEntries.isEmpty {
                Section("Behind dividers") {
                    ForEach(groupedEntries) { entry in row(entry) }
                }
            }
        }
        .overlay {
            if model.allOwnedEntries.isEmpty {
                ContentUnavailableView("Your Tin is empty", systemImage: "tray",
                                       description: Text("Scan cards and route them here to fill your Tin."))
            }
        }
        .navigationTitle("The Tin")
    }

    private func row(_ entry: CollectionEntry) -> some View {
        HStack {
            Text((try? store.card(id: entry.cardId))?.name ?? entry.cardId)
            if let v = entry.variantValue, v != .regular {
                Text(v.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let usd = model.entryValue(entry) {
                Text(usd, format: .currency(code: "USD")).foregroundStyle(.secondary)
            }
        }
    }
}
