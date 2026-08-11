import SwiftUI

/// One entry of the collection as a list row: art thumbnail, name, sleeve details, value —
/// plus which divider it lives behind when the list spans the whole tin.
struct CollectionEntryRow: View {
    let card: CardRecord?
    let entry: CollectionEntry
    var dividerName: String? = nil
    let value: Double?
    var delta: DeltaRecord? = nil
    /// Sold rows have no current value *by definition*, so they leave the price column empty
    /// rather than claiming the catalog failed them.
    var hidesNoData: Bool = false
    /// Given, the row carries a visible Edit chip between the name and the price. Editing used to
    /// be a long-press or a leading swipe — both invisible. Rows with no edit verb (trade pickers,
    /// the trade list) pass nothing and are unchanged.
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let card {
                CardImageView(card: card, quality: "low").frame(width: 44)
                VStack(alignment: .leading) {
                    Text(card.name).lineLimit(2)
                    Text("×\(entry.qty)\(entry.variantValue.map { " · \($0.label)" } ?? "")\(entry.condition.map { " · \($0)" } ?? "")\(entry.gradeValue.map { " · \($0.label)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let dividerName {
                        Text(dividerName).font(.caption2).foregroundStyle(.tertiary)
                    } else if let from = entry.acquiredFrom, !from.isEmpty {
                        Text("from \(from)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            // Without this the row squeezes the chip before the name and it
                            // renders as "Edi / t". The name truncates instead.
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Edit entry")
                }
                VStack(alignment: .trailing, spacing: 2) {
                    PriceLabel(value: value, hidesNoData: hidesNoData)
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
    @State private var labelRequest: LabelPrintRequest?
    var onGetStarted: ((CollectionView.GetStartedTab) -> Void)? = nil
    @State private var searchIndex = CardSearchIndex()
    // Bulk refiling — stock List multi-select, the same gesture Photos and Files use.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var choosingDestination = false
    @State private var showingNewDivider = false
    @State private var newDividerName = ""
    @State private var sellingEntry: CollectionEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The "Gone" section starts closed: it's history, not inventory, and on a collection sold
    /// down over years it would otherwise be the biggest thing on the screen.
    @State private var showingGone = false

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
                // Outside the empty branch on purpose: sell your last card and the stack IS
                // empty of things you own, but the history of what was there is exactly what
                // you'd have come looking for.
                if !isSelecting { goneSection }
            } else {
                searchResults
            }
        }
        .searchable(text: $searchText, prompt: group == nil ? "Search by name, set, or number" : "Search this divider")
        // The title carries the selection state — the count is the feedback that ticking worked,
        // and "Select cards to move" says what to do before anything is ticked.
        .navigationTitle(isSelecting
                         ? (selection.isEmpty ? "Select cards to move"
                            : "\(Self.cardCount(selection.count)) selected")
                         : title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.entries) {
            await model.portfolio.refresh(entries: model.allEntries, prices: model.prices,
                                          variantsByCard: model.variantsByCard,
                                          conditionsByCard: model.conditionsByCard,
                                          matrixByCard: model.matrixByCard,
                                          gradedByPrintingByCard: model.gradedByPrintingByCard)
        }
        .environment(\.editMode, $editMode)
        .toolbar { detailToolbar }
        .confirmationDialog("Move \(Self.cardCount(selection.count)) to…",
                            isPresented: $choosingDestination, titleVisibility: .visible) {
            destinationDialogActions
        }
        .alert("New divider", isPresented: $showingNewDivider) {
            newDividerAlertActions
        }
        .printSheetFlow($printRequest)
        .labelPrintFlow($labelRequest, store: store)
        .onChange(of: model.catalogGeneration) { searchIndex.clear() }
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
        .sheet(item: $sellingEntry) { entry in
            NavigationStack {
                MarkSoldSheet(card: try? store.card(id: entry.cardId), entry: entry,
                              marketValue: model.entryValue(entry)) { date, amount in
                    await model.markSold(entry, on: date, for: amount)
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
                    // A MENU, not two buttons: this toolbar already carries Sort and Select, and
                    // a fourth text-bearing item both eats the inline nav title and risks the
                    // iPadOS "third trailing item is silently dropped" behaviour CollectionView
                    // documents. One slot, both printables.
                    Menu {
                        Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                            label: { Label("Trade sheet", systemImage: "printer") }
                            .disabled(model.entries(in: group.id).isEmpty)
                        Button { labelRequest = LabelPrintRequest(title: group.name,
                                                                  entries: model.entries(in: group.id)) }
                            label: { Label("Card labels", systemImage: "qrcode") }
                            .disabled(model.entries(in: group.id).isEmpty)
                    } label: {
                        // Spelled out as an HStack, not a `Label` + `.labelStyle(.titleAndIcon)`:
                        // the toolbar overrides the label style and renders icon-only, which is
                        // exactly the problem — a lone printer glyph reads as "print the screen"
                        // when what it makes is a shareable PDF.
                        HStack(spacing: 4) {
                            Image(systemName: "printer")
                            Text("Print")
                        }
                    }
                    .accessibilityLabel("Print")
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

    /// "1 card" / "3 cards". Spelled out rather than `^[…](inflect: true)`: that markup only
    /// resolves where SwiftUI takes a LocalizedStringKey, and dialog titles / navigationTitle
    /// take a plain String — they render the raw markup instead. Matches how the rest of the
    /// app (TinRiffleRow, the delete dialogs) writes counts.
    private static func cardCount(_ n: Int) -> String { "\(n) \(n == 1 ? "card" : "cards")" }

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
                // Text-only: at .small the SF Symbols crowded the capsules and read as noise.
                HStack(spacing: 8) {
                    Button("Scan a card") { onGetStarted?(.scan) }
                        .buttonStyle(.borderedProminent)
                    Button("Browse sets") { onGetStarted?(.browse) }
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

    /// Cards that have left this stack. Collapsed, below everything, and never part of a total —
    /// the point of recording a sale is that it stops counting, while the card stays on the
    /// record. Empty ⇒ no section at all, so nobody who has never sold anything sees it.
    @ViewBuilder private var goneSection: some View {
        let gone = group.map { g in model.soldEntries.filter { $0.groupId == g.id } }
            ?? model.soldEntries
        if !gone.isEmpty {
            Section {
                if showingGone {
                    ForEach(gone) { entry in
                        // No value, and no "no data" either: what it went for is already in the
                        // caption, and this column reports what a card is worth *now*.
                        CollectionEntryRow(card: try? store.card(id: entry.cardId), entry: entry,
                                           dividerName: goneCaption(entry), value: nil,
                                           hidesNoData: true)
                            .foregroundStyle(.secondary)
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await model.markUnsold(entry) }
                                } label: { Label("Bring back", systemImage: "arrow.uturn.backward") }
                                    .tint(.blue)
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteEntry(id: entry.id) }
                                }
                            }
                    }
                }
            } header: {
                // An explicit toggle rather than `Section(isExpanded:)`: that API renders
                // differently across list styles, and this screen's style isn't pinned.
                Button {
                    withAnimation(reduceMotion ? nil : .default) { showingGone.toggle() }
                } label: {
                    HStack {
                        Text("Gone · \(gone.cardCount) \(gone.cardCount == 1 ? "card" : "cards")")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showingGone ? 90 : 0))
                            .font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Gone, \(gone.cardCount) \(gone.cardCount == 1 ? "card" : "cards")")
                .accessibilityHint(showingGone ? "Collapses the list" : "Expands the list")
            }
        }
    }

    /// "Sold 4 Mar for $180" / "Gone 4 Mar" when there was no cash figure (a trade or a gift).
    private func goneCaption(_ entry: CollectionEntry) -> String {
        let when = (entry.soldAt ?? Date()).formatted(.dateTime.day().month(.abbreviated))
        guard let got = entry.soldFor else { return "Gone \(when)" }
        return "Sold \(when) for \(got.formatted(.currency(code: "USD")))"
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

    // Tap still shows the card — the app-wide "open a card" verb — but editing was only ever a
    // long-press or a leading swipe, i.e. invisible. The row reads name · Edit · price · chevron:
    // the chip is the edit affordance, the chevron the one for details. While selecting there is
    // no chip: the tap belongs to the tick.
    @ViewBuilder
    private func row(_ entry: CollectionEntry, showDivider: Bool) -> some View {
        let content = CollectionEntryRow(
            card: try? store.card(id: entry.cardId),
            entry: entry,
            dividerName: showDivider
                ? model.groups.first(where: { $0.id == entry.groupId })?.name : nil,
            value: model.entryValue(entry),
            delta: deltaRecord(entry),
            onEdit: isSelecting ? nil : { editingEntry = entry })
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
        // Reveal-then-tap IS the confirmation (Notes/Reminders): a dialog after the swipe made the
        // row vanish, come back, and ask again. No full swipe, so it can't fire by accident.
        .swipeActions(allowsFullSwipe: false) {
            Button("Remove", role: .destructive) {
                Task { await model.deleteEntry(id: entry.id) }
            }
            // Beside Remove, because Remove is what people used to press for this — and it
            // erased the card, its cost basis and any record the sale ever happened.
            Button { sellingEntry = entry } label: { Label("Sold", systemImage: "bag") }
                .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            Button { editingEntry = entry } label: { Label("Edit", systemImage: "pencil") }
        }
        .contextMenu {
            Button { editingEntry = entry } label: { Label("Edit entry", systemImage: "pencil") }
            Button { sellingEntry = entry } label: { Label("Sold or traded…", systemImage: "bag") }
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
