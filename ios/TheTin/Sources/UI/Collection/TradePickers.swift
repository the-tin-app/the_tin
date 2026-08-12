import SwiftUI

/// Pick one of your own copies to put on the table.
///
/// Opens on the For Trade list, because that flag finally means something here — but every owned
/// copy is reachable below it. Trades happen to cards you hadn't decided to trade yet.
struct TradeOwnedPicker: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    let add: (CollectionEntry) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !forTrade.isEmpty {
                Section("On your trade list") { rows(forTrade) }
            }
            Section(forTrade.isEmpty ? "Your cards" : "Everything else") { rows(others) }
        }
        .searchable(text: $search, prompt: "Your cards")
        .navigationTitle("Your side")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .overlay {
            if forTrade.isEmpty && others.isEmpty {
                ContentUnavailableView("No cards match", systemImage: "magnifyingglass")
            }
        }
    }

    private var matching: [CollectionEntry] {
        guard !search.isEmpty else { return model.entries }
        let needle = search.lowercased()
        return model.entries.filter {
            (try? store.card(id: $0.cardId))?.name.lowercased().contains(needle) ?? false
        }
    }

    private var forTrade: [CollectionEntry] { matching.filter(\.isForTrade) }
    private var others: [CollectionEntry] { matching.filter { !$0.isForTrade } }

    @ViewBuilder private func rows(_ entries: [CollectionEntry]) -> some View {
        ForEach(entries) { entry in
            Button { add(entry) } label: {
                CollectionEntryRow(card: try? store.card(id: entry.cardId),
                                   entry: entry,
                                   dividerName: dividerName(entry),
                                   value: model.entryValue(entry))
            }
        }
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "No divider"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "No divider")
    }
}

/// Pick a card from the catalog for their side. They're cards you don't own, so there is nothing
/// local to pick from — this is the same offline FTS5 search the Search tab uses.
struct TradeCatalogPicker: View {
    let store: CatalogStore
    var wants: WantsModel? = nil
    /// Defaults to the trade wording it was written for. The virtual binder reuses this picker for
    /// "none of these — search instead", where "Their side" would be nonsense.
    var title: String = "Their side"
    let add: (CardRecord) -> Void

    @State private var model: SearchModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                list(model)
            } else {
                TinLoadingView(label: "Preparing search…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { if model == nil { model = SearchModel(store: store) } }
    }

    @ViewBuilder private func list(_ model: SearchModel) -> some View {
        @Bindable var model = model
        List(model.results) { card in
            Button { add(card) } label: {
                HStack(spacing: 12) {
                    CardImageView(card: card, quality: "low").frame(width: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(card.name).lineLimit(1)
                            // The whole reason to receive someone's list in the app: which of it
                            // you're actually hunting, without reading every name.
                            if wants?.isWanted(card.id) == true {
                                Image(systemName: "heart.fill")
                                    .font(.caption2).foregroundStyle(.pink) // contrast-ok: glyph, not text
                                    .accessibilityLabel("On your wanted list")
                            }
                        }
                        Text(model.caption(for: card))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let usd = model.prices[card.id]?.rawUsd {
                        Text(usd, format: WidgetShared.tinCurrency(usd))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $model.text, prompt: "Card name")
        .overlay {
            if model.results.isEmpty && !model.text.isEmpty {
                ContentUnavailableView.search(text: model.text)
            }
        }
    }
}
