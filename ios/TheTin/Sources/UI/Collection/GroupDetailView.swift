import SwiftUI

/// One entry of the collection as a list row: art thumbnail, name, sleeve details, value —
/// plus which divider it lives behind when the list spans the whole tin.
struct CollectionEntryRow: View {
    let card: CardRecord?
    let entry: CollectionEntry
    var dividerName: String? = nil
    let value: Double?

    var body: some View {
        HStack(spacing: 12) {
            if let card {
                CardImageView(card: card, quality: "low").frame(width: 44)
                VStack(alignment: .leading) {
                    Text(card.name)
                    Text("×\(entry.qty)\(entry.variantValue.map { " · \($0.label)" } ?? "")\(entry.condition.map { " · \($0)" } ?? "")\(entry.gradeValue.map { " · \($0.label)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let dividerName {
                        Text(dividerName).font(.caption2).foregroundStyle(.tertiary)
                    } else if let from = entry.acquiredFrom, !from.isEmpty {
                        Text("from \(from)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                PriceLabel(value: value)
            } else {
                Text(entry.cardId).font(.caption.monospaced())
            }
        }
    }
}

/// The list view of the tin — one divider's entries, or the whole collection when `group`
/// is nil ("Everything": No divider on top, then everything behind dividers). Searchable by
/// card name, so "do I own this?" is answerable from any list.
struct GroupDetailView: View {
    @Bindable var model: CollectionModel
    let group: CardGroup?   // nil = the whole tin ("Everything")
    let store: CatalogStore
    @State private var sortByValue = false
    @State private var searchText = ""
    @State private var editingEntry: CollectionEntry?
    @State private var printRequest: PrintSheetRequest?
    @State private var deletingEntry: CollectionEntry?
    var onGetStarted: ((CollectionView.GetStartedTab) -> Void)? = nil
    @State private var searchIndex = CardSearchIndex()

    var body: some View {
        List {
            if searchText.isEmpty {
                if scope.isEmpty {
                    emptyState   // instead of a "$0.00 · Priced 0 of 0" ledger for nothing
                } else {
                statsSection
                if let group {
                    entriesSection(model.sortedEntries(in: group.id, byValue: sortByValue),
                                   header: nil, showDivider: false)
                } else {
                    entriesSection(sortedAll(model.ungroupedEntries), header: "No divider", showDivider: false)
                    entriesSection(sortedAll(model.entries.filter { !$0.groupId.isEmpty }),
                                   header: "Behind dividers", showDivider: true)
                }
                }
            } else {
                searchResults
            }
        }
        .searchable(text: $searchText, prompt: group == nil ? "Search by name, set, or number" : "Search this divider")
        .navigationTitle(group?.name ?? "Everything")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sortByValue) {
                    Text("Newest first").tag(false)
                    Text("Highest value").tag(true)
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            if let group {
                Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                    label: { Label("Print sheet…", systemImage: "printer") }
                    .disabled(model.entries(in: group.id).isEmpty)
            }
        }
        .printSheetFlow($printRequest)
        .onChange(of: model.catalogGeneration) { searchIndex.clear() }
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
                    EntryFormView(card: card, groups: model.groups, existing: entry,
                                  variants: model.variantsByCard[entry.cardId] ?? [],
                                  conditions: model.conditionsByCard[entry.cardId] ?? []) { updated in
                        await model.saveEntry(updated)
                    }
                }
            }
        }
    }

    private var scope: [CollectionEntry] {
        group.map { model.entries(in: $0.id) } ?? model.entries
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 8) {
                Text(group.map { "Nothing behind “\($0.name)” yet." } ?? "Your tin is empty.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { onGetStarted?(.scan) } label: {
                        Label("Scan a card", systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { onGetStarted?(.browse) } label: {
                        Label("Browse sets", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var statsSection: some View {
        Section {
            let value = group.map { model.groupValue($0.id) } ?? model.tinValue
            VStack(alignment: .leading, spacing: 4) {
                Text(value.total, format: .currency(code: "USD")).font(.title2.bold()).monospacedDigit()
                Text("Priced \(value.pricedCards) of \(value.totalCards) cards")
                    .font(.caption).foregroundStyle(.secondary)
                if let asOf = try? store.priceAsOf() { AsOfLabel(date: asOf) }
            }
        }
    }

    @ViewBuilder
    private func entriesSection(_ entries: [CollectionEntry], header: String?, showDivider: Bool) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in row(entry, showDivider: showDivider) }
            } header: {
                if let header { Text(header) }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let matches = scope.filter { searchIndex.matches($0, query: searchText, store: store) }
        if matches.isEmpty {
            ContentUnavailableView {
                Label("No matches for “\(searchText)” here", systemImage: "magnifyingglass")
            } description: {
                Text("Your tin only searches cards you own — the Search tab covers the whole catalog.")
            }
        } else {
            entriesSection(sortedAll(matches), header: nil, showDivider: group == nil)
        }
    }

    // Tap shows the card — the app-wide "open a card" verb (the cards are the hero);
    // editing is the deliberate second gesture, on leading swipe + long-press.
    private func row(_ entry: CollectionEntry, showDivider: Bool) -> some View {
        NavigationLink(value: CardID(raw: entry.cardId)) {
            CollectionEntryRow(
                card: try? store.card(id: entry.cardId),
                entry: entry,
                dividerName: showDivider
                    ? model.groups.first(where: { $0.id == entry.groupId })?.name : nil,
                value: model.entryValue(entry))
        }
        .swipeActions {
            Button("Remove", role: .destructive) { deletingEntry = entry }
        }
        .swipeActions(edge: .leading) {
            Button { editingEntry = entry } label: { Label("Edit", systemImage: "pencil") }
        }
        .contextMenu {
            Button { editingEntry = entry } label: { Label("Edit entry", systemImage: "pencil") }
        }
    }

    private func sortedAll(_ entries: [CollectionEntry]) -> [CollectionEntry] {
        sortByValue ? GroupStats.sortedByValueDescending(entries: entries, prices: model.prices,
                                                         variantsByCard: model.variantsByCard,
                                                         conditionsByCard: model.conditionsByCard)
                    : entries.sorted { $0.addedAt > $1.addedAt }
    }

    private func cardName(_ entry: CollectionEntry) -> String {
        searchIndex.name(for: entry, store: store)
    }
}
