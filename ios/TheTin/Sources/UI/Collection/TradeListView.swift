import SwiftUI

/// Route to the trade list (marker type, like `WantedRoute`).
struct TradeRoute: Hashable {}

/// The cards you've said you'll part with, most valuable first.
///
/// Spares are the currency of this hobby and the app had no notion of them: a fourth copy was
/// just "×4" in the tin total, and the only trade affordance in the whole app was a print action
/// buried in a divider's long-press menu. This is the list you actually bring to a meetup — and
/// what the shareable trade link is built from.
struct TradeListView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    @State private var editingEntry: CollectionEntry?

    var body: some View {
        List {
            if !model.tradeEntries.isEmpty {
                Section {
                    header
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(model.tradeEntries) { entry in
                        NavigationLink(value: CardID(raw: entry.cardId)) {
                            CollectionEntryRow(card: try? store.card(id: entry.cardId),
                                               entry: entry,
                                               dividerName: dividerName(entry),
                                               value: model.entryValue(entry))
                        }
                        .swipeActions(edge: .trailing) {
                            // Not a delete: taking a card off the trade list must never look like
                            // it might remove it from the tin.
                            Button {
                                Task { await model.setForTrade(entry, false) }
                            } label: {
                                Label("Keep", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .leading) {
                            Button { editingEntry = entry } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                    }
                } footer: {
                    let v = model.tradeValue
                    if v.pricedCards < v.totalCards {
                        Text("\(v.pricedCards) of \(v.totalCards) cards priced.")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if model.tradeEntries.isEmpty { emptyState } }
        .navigationTitle("For Trade")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            if let card = try? store.card(id: entry.cardId) {
                NavigationStack {
                    EntryFormView(card: card, groups: model.groups, existing: entry,
                                  variants: model.variantsByCard[entry.cardId] ?? [],
                                  conditions: model.conditionsByCard[entry.cardId] ?? [],
                                  matrix: model.matrixByCard[entry.cardId] ?? []) { updated in
                        await model.saveEntry(updated)
                    }
                }
            }
        }
    }

    private var header: some View {
        let v = model.tradeValue
        return VStack(alignment: .leading, spacing: 2) {
            Text(v.total, format: WidgetShared.tinCurrency(v.total))
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text("\(v.totalCards) \(v.totalCards == 1 ? "card" : "cards") you'll trade")
                .font(.footnote).foregroundStyle(.secondary)
            if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
        }
    }

    /// Marking is explicit by design — which means without this the screen is blank forever, and
    /// a blank screen on first visit reads as broken rather than as empty.
    private var emptyState: some View {
        let duplicates = model.duplicateCardIds.count
        return ContentUnavailableView {
            Label("No cards marked to trade", systemImage: "arrow.left.arrow.right")
        } description: {
            Text(duplicates == 0
                 ? "Turn on “Available to trade” when you edit a card and it collects here."
                 : "Turn on “Available to trade” when you edit a card — or start from the cards you hold more than one of.")
        } actions: {
            if duplicates > 0 {
                Button("Flag \(duplicates) \(duplicates == 1 ? "duplicate" : "duplicates")") {
                    Task { await model.flagDuplicatesForTrade() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "No divider"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "No divider")
    }
}
