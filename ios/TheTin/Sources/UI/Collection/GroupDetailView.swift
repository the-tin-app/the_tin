import SwiftUI

/// One entry of the collection as a list row: art thumbnail, name, sleeve details, value —
/// plus which divider it lives behind when the list spans the whole tin.
struct CollectionEntryRow: View {
    let card: CardRecord?
    let entry: CollectionEntry
    var dividerName: String? = nil
    let value: Double?
    var delta: DeltaRecord? = nil

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
                VStack(alignment: .trailing, spacing: 2) {
                    PriceLabel(value: value)
                    DeltaBadge(record: delta)
                }
            } else {
                Text(entry.cardId).font(.caption.monospaced())
            }
        }
    }
}

/// A divider's list-first landing (or the whole tin's when `group` is nil — "Everything":
/// No divider on top, then everything behind dividers): summary plaque, that stack's
/// performance over time, then the cards themselves. The swipe deck (`GroupPagerView`) is the
/// explicit "Flip through" mode. Searchable, so "do I own this?" is answerable from any list.
struct GroupDetailView: View {
    /// Entry orderings offered by the toolbar sort menu.
    private enum EntrySort: String, CaseIterable, Identifiable {
        case newest = "Newest first", value = "Highest value", name = "A to Z"
        var id: String { rawValue }
    }

    @Bindable var model: CollectionModel
    let group: CardGroup?   // nil = the whole tin ("Everything")
    let store: CatalogStore
    @State private var sort: EntrySort = .newest
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
                    entriesSection(sortedAll(model.entries(in: group.id)), header: nil, showDivider: false)
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.entries) {
            await model.portfolio.refresh(entries: model.entries, prices: model.prices,
                                          variantsByCard: model.variantsByCard,
                                          conditionsByCard: model.conditionsByCard,
                                          matrixByCard: model.matrixByCard,
                                          gradedByPrintingByCard: model.gradedByPrintingByCard)
        }
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(EntrySort.allCases) { Text($0.rawValue).tag($0) }
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
                                  conditions: model.conditionsByCard[entry.cardId] ?? [],
                                  matrix: model.matrixByCard[entry.cardId] ?? []) { updated in
                        await model.saveEntry(updated)
                    }
                }
            }
        }
    }

    private var scope: [CollectionEntry] {
        group.map { model.entries(in: $0.id) } ?? model.entries
    }

    private var title: String { group?.name ?? "Everything" }
    private var color: Color { group.map { DividerPalette.color(for: $0.id) } ?? DividerPalette.steel }
    private var tier: CatalogTier { CatalogTier(rawValue: AppConfig.catalogTier) ?? .average }

    /// This stack's portfolio series — the divider's own, or the whole tin's for "Everything".
    private var series: PortfolioSeries? {
        if let group { return model.portfolio.groupSeries[group.id] }
        return model.portfolio.series
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

    /// The divider tab blown up into a title plaque (kept from the old pager summary),
    /// then this stack's performance and the flip-through mode switch.
    private var statsSection: some View {
        Section {
            let value = group.map { model.groupValue($0.id) } ?? model.tinValue
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.largeTitle, design: .serif).italic().weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(value.total, format: .currency(code: "USD"))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Priced \(value.pricedCards) of \(value.totalCards) \(value.totalCards == 1 ? "card" : "cards")")
                    .font(.footnote).foregroundStyle(.secondary)
                if let asOf = try? store.priceAsOf() { AsOfLabel(date: asOf) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24).padding(.horizontal)
            .background(color.opacity(0.3), in: UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 6,
                bottomTrailingRadius: 6, topTrailingRadius: 18))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            performanceRow
            NavigationLink(value: TinPagerRoute(groupId: group?.id)) {
                Label("Flip through your cards", systemImage: "rectangle.stack")
            }
        }
    }

    /// This stack's value over time, right on the landing (2026-07-17 UX pass: a divider's
    /// performance lives with the divider). Tap → the full range-picking PortfolioView.
    /// Casual tier has no `price_history` — no row at all (the portfolio screen itself
    /// explains the tier trade-off from the tin header).
    @ViewBuilder private var performanceRow: some View {
        if tier != .casual, let series {
            if series.cardsWithHistory > 0 {
                NavigationLink(value: PortfolioRoute(groupId: group?.id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Performance").font(.headline)
                        Sparkline(points: series.points.map { PricePoint(date: $0.date, value: $0.value) },
                                  color: .accentColor)
                            .frame(height: 56)
                        if series.cardsWithHistory < series.totalCards {
                            Text("Based on \(series.cardsWithHistory) of \(series.totalCards) cards with price history.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Performance chart. Shows value over time.")
            } else {
                Label("No price history yet — check back after the next catalog update.",
                      systemImage: "chart.line.uptrend.xyaxis")
                    .font(.footnote).foregroundStyle(.secondary)
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
                value: model.entryValue(entry),
                delta: deltaRecord(entry))
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

    /// The delta matching what this entry actually is (spec 2026-07-18): a graded copy tracks its
    /// grade, an ungraded copy its printing when that printing has a delta, else the raw market.
    private func deltaRecord(_ entry: CollectionEntry) -> DeltaRecord? {
        let records = model.deltasByCard[entry.cardId] ?? []
        if let grade = entry.gradeValue {
            return records.first { $0.kind == .psa && $0.key == String(grade.numeric) }
        }
        if let variant = entry.variantValue,
           let printing = records.first(where: { $0.kind == .printing && variant.matches(printing: $0.key) }) {
            return printing
        }
        return records.first { $0.kind == .raw }
    }

    private func sortedAll(_ entries: [CollectionEntry]) -> [CollectionEntry] {
        switch sort {
        case .newest:
            return entries.sorted { $0.addedAt > $1.addedAt }
        case .value:
            return GroupStats.sortedByValueDescending(entries: entries, prices: model.prices,
                                                      variantsByCard: model.variantsByCard,
                                                      conditionsByCard: model.conditionsByCard,
                                                      matrixByCard: model.matrixByCard,
                                                      gradedByPrintingByCard: model.gradedByPrintingByCard)
        case .name:
            return entries.sorted {
                searchIndex.name(for: $0, store: store)
                    .localizedStandardCompare(searchIndex.name(for: $1, store: store)) == .orderedAscending
            }
        }
    }

    private func cardName(_ entry: CollectionEntry) -> String {
        searchIndex.name(for: entry, store: store)
    }
}
