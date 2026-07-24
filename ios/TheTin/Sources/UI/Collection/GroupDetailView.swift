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
    // Bulk refiling — stock List multi-select, the same gesture Photos and Files use.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var choosingDestination = false
    @State private var showingNewDivider = false
    @State private var newDividerName = ""

    var body: some View {
        List(selection: $selection) {
            if searchText.isEmpty {
                if scope.isEmpty {
                    emptyState   // instead of a "$0.00 · Priced 0 of 0" ledger for nothing
                } else {
                // While selecting, the cards ARE the screen: the plaque + performance chart push
                // the first row below the fold, which reads as "there's nothing here to tick".
                if !isSelecting { statsSection }
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
        // The title carries the selection state — the count is the feedback that ticking worked,
        // and "Select cards to move" says what to do before anything is ticked.
        .navigationTitle(isSelecting
                         ? (selection.isEmpty ? "Select cards to move"
                            : "^[\(selection.count) card](inflect: true) selected")
                         : title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.entries) {
            await model.portfolio.refresh(entries: model.entries, prices: model.prices,
                                          variantsByCard: model.variantsByCard,
                                          conditionsByCard: model.conditionsByCard,
                                          matrixByCard: model.matrixByCard,
                                          gradedByPrintingByCard: model.gradedByPrintingByCard)
        }
        .environment(\.editMode, $editMode)
        .toolbar { detailToolbar }
        .confirmationDialog("Move ^[\(selection.count) card](inflect: true) to…",
                            isPresented: $choosingDestination, titleVisibility: .visible) {
            destinationDialogActions
        }
        .alert("New divider", isPresented: $showingNewDivider) {
            newDividerAlertActions
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

    // Broken out of `body` for the same reason as CardDetailView's toolbar: inline, the whole
    // modifier chain blows the type checker's time budget.
    /// Selection mode replaces the whole toolbar rather than adding to it: Sort and Print don't
    /// apply to a selection, and the actions that DO have to be the obvious things on screen.
    /// Nothing lives in `.bottomBar` — this view is inside a TabView, where the tab bar owns that
    /// space and a bottom-bar item is easily missed or not shown at all.
    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Move…") { choosingDestination = true }
                    .disabled(selection.isEmpty)
                    .fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishMoving() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(scope.map(\.id))
                }
            }
        } else {
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(EntrySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            if let group {
                ToolbarItem {
                    Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                        label: { Label("Print sheet…", systemImage: "printer") }
                        .disabled(model.entries(in: group.id).isEmpty)
                }
            }
            if !scope.isEmpty {
                ToolbarItem {
                    Button("Select") {
                        selection.removeAll()
                        editMode = .active
                    }
                }
            }
        }
    }

    private var isSelecting: Bool { editMode == .active }
    private var allSelected: Bool { !scope.isEmpty && selection.count == scope.count }

    @ViewBuilder private var destinationDialogActions: some View {
        Button("No divider") { move(to: "") }
        ForEach(model.groups.filter { $0.id != group?.id }) { g in
            Button(g.name) { move(to: g.id) }
        }
        Button("New divider…") { showingNewDivider = true }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder private var newDividerAlertActions: some View {
        TextField("Name", text: $newDividerName)
        Button("Create") {
            let name = newDividerName.trimmingCharacters(in: .whitespaces)
            newDividerName = ""
            guard !name.isEmpty else { return }
            let moving = selection
            Task {
                let id = await model.createGroup(name: name)
                guard !id.isEmpty else { return }   // creation failed; it already alerted
                await model.moveEntries(ids: moving, toGroup: id)
                finishMoving()
            }
        }
        Button("Cancel", role: .cancel) { newDividerName = "" }
    }

    private func move(to groupId: String) {
        let moving = selection
        Task {
            await model.moveEntries(ids: moving, toGroup: groupId)
            finishMoving()
        }
    }

    /// Leave selection mode after a move — the moved rows are gone from this list (or folded
    /// into another row), so keeping stale ids selected only invites a second wrong move.
    private func finishMoving() {
        selection.removeAll()
        editMode = .inactive
    }

    /// Any owned card carries change data — gates the period picker (empty on the casual tier).
    private var hasDeltas: Bool {
        model.deltasByCard.values.contains { $0.contains(where: { $0.hasData }) }
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
            // App-wide selector for the per-row change badges below — only when there's data.
            if hasDeltas {
                HStack(spacing: 8) {
                    Text("Change vs").font(.caption2).foregroundStyle(.secondary)
                    DeltaPeriodPicker().fixedSize()
                    Spacer()
                }
            }
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
    @ViewBuilder
    private func row(_ entry: CollectionEntry, showDivider: Bool) -> some View {
        let content = CollectionEntryRow(
            card: try? store.card(id: entry.cardId),
            entry: entry,
            dividerName: showDivider
                ? model.groups.first(where: { $0.id == entry.groupId })?.name : nil,
            value: model.entryValue(entry),
            delta: deltaRecord(entry))
        // A NavigationLink row owns its own tap, so in selection mode it eats the tick instead of
        // toggling — the row has to be a plain, selectable row while selecting. `.tag` pins the
        // selection identity either way rather than leaving it to be inferred.
        Group {
            if isSelecting {
                content
            } else {
                NavigationLink(value: CardID(raw: entry.cardId)) { content }
            }
        }
        .tag(entry.id)
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

    /// The delta matching what this entry actually is — resolved by the same ladder as its value
    /// (`GroupStats.unitPrice`) so the change tracks the price the row shows, not the raw market.
    private func deltaRecord(_ entry: CollectionEntry) -> DeltaRecord? {
        GroupStats.unitDelta(entry, records: model.deltasByCard[entry.cardId] ?? [])
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
