import SwiftUI
import Observation

@MainActor @Observable
final class CollectionModel {
    private let repository: CollectionRepository
    private let store: CatalogStore
    /// Portfolio-history model, app-lifetime so its series cache survives screen pushes.
    let portfolio: PortfolioModel
    private(set) var groups: [CardGroup] = []
    private(set) var entries: [CollectionEntry] = []
    private(set) var prices: [String: PriceRecord] = [:]
    private(set) var variantsByCard: [String: [VariantPrice]] = [:]
    private(set) var conditionsByCard: [String: [ConditionPrice]] = [:]
    private var streamTasks: [Task<Void, Never>] = []
    /// Mirrors the header's numbers to the home-screen widget. nil until AppModel injects one
    /// (and in unit tests that don't care) — publishing is then a no-op.
    var widgetWriter: WidgetSnapshotWriter?
    /// In-flight off-main widget-snapshot compute; cancelled/superseded on the next entries-stream
    /// emission. The task itself is the detached compute (see `publishWidgetSnapshot`), so
    /// `cancel()` genuinely stops it — checked before the expensive series compute, and again
    /// inside the MainActor hop immediately before `schedule(...)` (not before the hop: a check
    /// before the `await MainActor.run` suspension point can pass, then lose a race to a
    /// superseding task before it resumes, and schedule a stale write anyway).
    private var widgetSnapshotTask: Task<Void, Never>?

    init(repository: CollectionRepository, store: CatalogStore) {
        self.repository = repository
        self.store = store
        self.portfolio = PortfolioModel(store: store)
    }

    func start() async {
        guard streamTasks.isEmpty else { return }
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.repository.groupsStream() else { return }
            for await groups in stream { self?.groups = groups }
        })
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.repository.entriesStream() else { return }
            for await entries in stream {
                self?.entries = entries
                self?.reloadPrices()
                self?.publishWidgetSnapshot()
            }
        })
    }

    /// The catalog artifact was swapped under the live store (daily update installed
    /// mid-session) — recompute everything cached from it.
    func catalogDidChange() {
        reloadPrices()
        publishWidgetSnapshot()
    }

    private func reloadPrices() {
        let ids = Array(Set(entries.map(\.cardId)))
        prices = (try? store.prices(cardIds: ids)) ?? [:]
        variantsByCard = (try? store.variantPrices(cardIds: ids)) ?? [:]
        conditionsByCard = (try? store.conditionPrices(cardIds: ids)) ?? [:]
    }

    func entries(in groupId: String) -> [CollectionEntry] {
        entries.filter { $0.groupId == groupId }
    }

    var allOwnedEntries: [CollectionEntry] { entries.sorted { $0.addedAt > $1.addedAt } }
    var ungroupedEntries: [CollectionEntry] { entries.filter { $0.groupId == "" } }

    /// Value of one entry, using everything the user saved (grade → condition → printing). nil
    /// when the recorded condition has no price of its own (e.g. DMG with no `price_by_condition`
    /// row) — display should read "no data", not silently substitute an NM/raw estimate.
    func entryValue(_ entry: CollectionEntry) -> Double? {
        let variants = variantsByCard[entry.cardId] ?? []
        let conditions = conditionsByCard[entry.cardId] ?? []
        guard GroupStats.isPricedExactly(entry, price: prices[entry.cardId], variants: variants, conditions: conditions)
        else { return nil }
        return GroupStats.entryValue(entry, price: prices[entry.cardId], variants: variants, conditions: conditions)
    }

    func groupValue(_ groupId: String) -> (total: Double, pricedEntries: Int, totalEntries: Int) {
        GroupStats.totalValue(entries: entries(in: groupId), prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard)
    }

    /// The whole tin's value across every group and ungrouped card.
    var tinValue: (total: Double, pricedEntries: Int, totalEntries: Int) {
        GroupStats.totalValue(entries: entries, prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard)
    }

    /// One snapshot per tin-total recompute — the same numbers the Collection header shows,
    /// plus 7-day movement from the portfolio series when history data exists (average/expert
    /// tier; empty history ⇒ value-only snapshot, widget hides the Δ row and sparkline — gated
    /// on `series.cardsWithHistory > 0`, not just `points.count`: with zero history coverage
    /// `PortfolioHistory.series` still buckets ≥2 points from `ownedDates` alone, flat at the
    /// current value — a real-looking but informationless "trend").
    ///
    /// The history-fetch + `PortfolioHistory.series` compute is one SQL query per priced card —
    /// too slow to run synchronously on @MainActor on every entries-stream emission. `widgetSnapshotTask`
    /// itself IS the detached compute (mirroring `PortfolioModel.refresh`), so a superseded
    /// emission's `cancel()` genuinely stops the in-flight work — checked before the expensive
    /// series compute, and again *inside* the `MainActor.run` closure right before `schedule(...)`,
    /// not just the final write. That second check must live inside the closure, not before the
    /// `await`: a superseding `publishWidgetSnapshot` call also runs on the MainActor (it does
    /// `cancel()` then creates the new task), so it can't interleave mid-closure — check-then-schedule
    /// is atomic and a stale compute can never overwrite a newer snapshot. Snapshotting
    /// `v`/`entries`/`prices`/etc. synchronously on @MainActor before creating the task (and
    /// cancelling the old one first) is what makes that guarantee hold from the very first line.
    private func publishWidgetSnapshot() {
        guard widgetWriter != nil else { return }
        widgetSnapshotTask?.cancel()
        let v = tinValue
        let entries = self.entries
        let prices = self.prices
        let variantsByCard = self.variantsByCard
        let conditionsByCard = self.conditionsByCard
        let asOf = prices.values.map(\.asOf).max()   // "yyyy-MM-dd" sorts lexicographically
        let store = self.store   // @unchecked Sendable — safe to hand to a detached task
        widgetSnapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let ids = Array(Set(entries.map(\.cardId)))
            let histories = (try? store.priceHistory(cardIds: ids)) ?? [:]
            let series = PortfolioHistory.series(entries: entries, histories: histories,
                                                 prices: prices, variantsByCard: variantsByCard,
                                                 conditionsByCard: conditionsByCard)
            var delta7d: Double?
            var sparkline: [Double]?
            if series.points.count >= 2, series.cardsWithHistory > 0, let last = series.points.last {
                let cutoff = last.date.addingTimeInterval(-7 * 86_400)
                if let base = series.points.last(where: { $0.date <= cutoff }), base.value > 0 {
                    delta7d = (last.value - base.value) / base.value
                }
                sparkline = series.points.suffix(12).map(\.value)
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.widgetWriter?.schedule(WidgetSnapshot(
                    totalValue: v.total,
                    cardCount: entries.cardCount,
                    delta7d: delta7d,
                    sparkline: sparkline,
                    asOf: asOf,
                    updatedAt: Date()))
            }
        }
    }

    func sortedEntries(in groupId: String, byValue: Bool) -> [CollectionEntry] {
        let list = entries(in: groupId)
        return byValue ? GroupStats.sortedByValueDescending(entries: list, prices: prices,
                                                            variantsByCard: variantsByCard,
                                                            conditionsByCard: conditionsByCard)
                       : list.sorted { $0.addedAt > $1.addedAt }
    }

    /// Set when a collection write fails (disk full, etc.); MainTabView presents it as an
    /// alert wherever the user is. The repository rolls failed writes back, so "wasn't saved"
    /// is literally what the UI now shows.
    var writeError: WriteError?
    struct WriteError: Equatable { let message: String }

    /// Run a repository write; on failure surface an alert phrased around `what`
    /// ("save the card", "delete the divider") and report false.
    @discardableResult
    private func write(_ what: String, _ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true }
        catch {
            writeError = WriteError(message: "Couldn't \(what) — nothing was changed. Check free storage and try again.")
            return false
        }
    }

    @discardableResult
    func createGroup(name: String) async -> String {
        var id = ""
        await write("create the divider") { id = try await repository.createGroup(name: name) }
        return id
    }
    func renameGroup(id: String, name: String) async {
        await write("rename the divider") { try await repository.renameGroup(id: id, name: name) }
    }
    func deleteGroup(id: String) async {
        await write("delete the divider") { try await repository.deleteGroup(id: id) }
    }
    func reorderGroups(ids: [String]) async {
        await write("reorder the dividers") { try await repository.reorderGroups(orderedIds: ids) }
    }

    @discardableResult
    func saveEntry(_ entry: CollectionEntry) async -> Bool {
        if entries.contains(where: { $0.id == entry.id }) {
            await write("save the card") { try await repository.updateEntry(entry) }
        } else {
            await write("save the card") { try await repository.addEntry(entry) }
        }
    }

    /// Batch add (CSV import) — one repository write + one stream notification for the whole
    /// set, instead of N round trips through `saveEntry`.
    func addEntries(_ entries: [CollectionEntry]) async {
        await write("import the cards") { try await repository.addEntries(entries) }
    }

    func moveEntry(_ entry: CollectionEntry, toGroup groupId: String) async {
        var moved = entry
        moved.groupId = groupId
        await saveEntry(moved)
    }

    func deleteEntry(id: String) async {
        await write("remove the card") { try await repository.deleteEntry(id: id) }
    }

    /// Commit a scanned draft into the owned collection. Returns false on write failure so the
    /// caller can keep the draft in staging and let the user retry. `.tin` = ungrouped (groupId "").
    func commitScan(_ draft: ScanDraft, to destination: RouteDestination) async -> Bool {
        let groupId: String
        switch destination {
        case .group(let id): groupId = id
        case .tin: groupId = ""
        case .newGroup(let name):
            let id = await createGroup(name: name)
            guard !id.isEmpty else { return false }
            groupId = id
        }
        let entry = CollectionEntry(id: UUID().uuidString, cardId: draft.cardId, groupId: groupId,
                                    qty: draft.qty, condition: draft.condition.rawValue, grade: nil,
                                    pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date(),
                                    variant: draft.variant.rawValue)
        do { try await repository.addEntry(entry); return true }
        catch { return false }
    }
}

struct TinAllCardsRoute: Hashable {}

/// Route to a group's swipeable pager. nil groupId = the whole tin ("Everything").
struct TinPagerRoute: Hashable { let groupId: String? }

/// Muted index-card tones for divider tabs, stable per group id (djb2 — Swift's Hasher is
/// seeded per launch, so it can't pick a persistent color).
enum DividerPalette {
    static let colors: [Color] = [
        Color(red: 0.91, green: 0.84, blue: 0.64),  // manila
        Color(red: 0.66, green: 0.78, blue: 0.88),  // sky
        Color(red: 0.71, green: 0.79, blue: 0.66),  // sage
        Color(red: 0.85, green: 0.65, blue: 0.60),  // clay
        Color(red: 0.73, green: 0.64, blue: 0.79),  // plum
        Color(red: 0.85, green: 0.80, blue: 0.71),  // sand
        Color(red: 0.58, green: 0.77, blue: 0.75),  // teal
        Color(red: 0.86, green: 0.67, blue: 0.75),  // rose
    ]
    /// Steel tone for the "Everything" stack — the tin itself, not a paper divider.
    static let steel = Color(red: 0.72, green: 0.74, blue: 0.77)

    static func color(for id: String) -> Color {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return colors[Int(h % UInt64(colors.count))]
    }
}


/// The Collection tab: your tin as a vertical list of riffle rows — one full-width tray per
/// divider, its cards spread newest-first behind a colored index tab. Tap a row to flip through
/// it; long-press for rename/delete/list; the reorder toolbar button turns on drag handles.
struct CollectionView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    var wants: WantsModel? = nil
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var renamingGroupId: String?
    @State private var renameGroupName = ""
    @State private var editMode: EditMode = .inactive
    @State private var printRequest: PrintSheetRequest?
    @State private var showingReport = false
    @State private var deletingGroup: CardGroup?
    @State private var searchText = ""
    @State private var editingEntry: CollectionEntry?
    /// cardId → name for search filtering (reference type: filled during body evaluation).
    private final class NameCache { var names: [String: String] = [:] }
    @State private var nameCache = NameCache()

    /// How many cards a riffle row spreads before collapsing into "+N".
    private static let riffleLimit = 7

    var body: some View {
        List {
            if searchText.isEmpty {
                header.tinRow()
                everythingRow.tinRow()
                ForEach(model.groups) { group in
                    groupRow(group).tinRow()
                }
                .onMove { from, to in
                    var ids = model.groups.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderGroups(ids: ids) }
                }
                newDividerRow.tinRow()
                if let wants { wishlistLink(wants).tinRow() }
            } else {
                searchResults
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search your tin")
        .environment(\.editMode, $editMode)
        .printSheetFlow($printRequest)
        .collectionReportFlow(isActive: $showingReport, collection: model, store: store)
        .navigationTitle("The Tin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.groups.count > 1 {
                Button {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
                .accessibilityLabel(editMode == .active ? "Done reordering" : "Reorder dividers")
            }
            Button { showingNewGroup = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("New divider")
            Menu {
                Button { showingReport = true }
                    label: { Label("Collection report (PDF)", systemImage: "doc.text") }
                    .disabled(model.entries.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More")
        }
        .alert("New divider", isPresented: $showingNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                newGroupName = ""
                guard !name.isEmpty else { return }
                Task { await model.createGroup(name: name) }
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .alert("Rename divider", isPresented: Binding(
            get: { renamingGroupId != nil },
            set: { if !$0 { renamingGroupId = nil } }
        )) {
            TextField("Name", text: $renameGroupName)
            Button("Save") {
                let id = renamingGroupId
                let name = renameGroupName.trimmingCharacters(in: .whitespaces)
                renamingGroupId = nil
                renameGroupName = ""
                guard let id, !name.isEmpty else { return }
                Task { await model.renameGroup(id: id, name: name) }
            }
            Button("Cancel", role: .cancel) {
                renamingGroupId = nil
                renameGroupName = ""
            }
        }
        .confirmationDialog(
            "Delete “\(deletingGroup?.name ?? "")”?",
            isPresented: Binding(get: { deletingGroup != nil },
                                 set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible,
            presenting: deletingGroup
        ) { group in
            let n = model.entries(in: group.id).cardCount
            Button(n == 0 ? "Delete divider" : "Delete divider and \(n) \(n == 1 ? "card" : "cards")",
                   role: .destructive) {
                Task { await model.deleteGroup(id: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            let n = model.entries(in: group.id).cardCount
            Text(n == 0 ? "This divider is empty."
                        : "Its \(n) \(n == 1 ? "card" : "cards") will be removed from your tin too. This can't be undone.")
        }
        .navigationDestination(for: TinPagerRoute.self) { route in
            GroupPagerView(model: model, store: store, groupId: route.groupId)
        }
        .navigationDestination(for: PortfolioRoute.self) { route in
            PortfolioView(model: model, groupId: route.groupId)
        }
        .navigationDestination(for: String.self) { groupId in
            if let group = model.groups.first(where: { $0.id == groupId }) {
                GroupDetailView(model: model, group: group, store: store)
            }
        }
        .navigationDestination(for: WantedRoute.self) { _ in
            if let wants { WantedCardsView(store: store, wants: wants, collection: model) }
        }
        .navigationDestination(for: TinAllCardsRoute.self) { _ in
            GroupDetailView(model: model, group: nil, store: store)
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
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: CatalogPriceHistory(store: store)),
                               store: store, collection: model, wants: wants)
            }
        }
    }

    private var header: some View {
        let v = model.tinValue
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(v.total, format: WidgetShared.tinCurrency(v.total))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .background(navLink(PortfolioRoute()))
            .accessibilityLabel("Portfolio value history")
            Text(model.entries.isEmpty
                 ? "Your tin is empty — scan a card or browse a set to add your first."
                 : "\(model.entries.cardCount) cards in your tin · \(v.pricedEntries) of \(v.totalEntries) priced")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    private var everythingRow: some View {
        let entries = model.allOwnedEntries
        return TinRiffleRow(name: "Everything", color: DividerPalette.steel,
                            cards: riffleCards(entries), count: entries.cardCount,
                            value: model.tinValue.total)
            .background(navLink(TinPagerRoute(groupId: nil)))
            .contextMenu {
                NavigationLink(value: TinAllCardsRoute()) { Label("Open as list", systemImage: "list.bullet") }
            }
    }

    private func groupRow(_ group: CardGroup) -> some View {
        let entries = model.entries(in: group.id).sorted { $0.addedAt > $1.addedAt }
        return TinRiffleRow(name: group.name, color: DividerPalette.color(for: group.id),
                            cards: riffleCards(entries), count: entries.cardCount,
                            value: model.groupValue(group.id).total)
            .background(navLink(TinPagerRoute(groupId: group.id)))
            .contextMenu {
                Button { renameGroupName = group.name; renamingGroupId = group.id }
                    label: { Label("Rename", systemImage: "pencil") }
                NavigationLink(value: group.id) { Label("Open as list", systemImage: "list.bullet") }
                Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                    label: { Label("Print sheet…", systemImage: "printer") }
                    .disabled(model.entries(in: group.id).isEmpty)
                Button(role: .destructive) { deletingGroup = group }
                    label: { Label("Delete divider", systemImage: "trash") }
            }
    }

    /// Invisible NavigationLink behind a custom row — keeps the tap-to-push without List's
    /// trailing disclosure chevron cutting into the riffle.
    private func navLink<V: Hashable>(_ value: V) -> some View {
        NavigationLink(value: value) { EmptyView() }.opacity(0)
    }

    /// The distinct cards a row spreads, newest first.
    private func riffleCards(_ entries: [CollectionEntry]) -> [CardRecord] {
        var seen = Set<String>()
        var out: [CardRecord] = []
        for e in entries where seen.insert(e.cardId).inserted {
            if let c = try? store.card(id: e.cardId) { out.append(c) }
            if out.count == Self.riffleLimit { break }
        }
        return out
    }

    private var newDividerRow: some View {
        Button { showingNewGroup = true } label: {
            Label("New divider", systemImage: "plus")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                }
        }
        .buttonStyle(.plain)
    }

    /// Whole-collection search: "do I own this?" answered from the Tin root. Rows carry the
    /// divider the copy lives behind; tap opens the entry editor.
    @ViewBuilder private var searchResults: some View {
        let matches = model.entries
            .filter { cardName($0).localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.addedAt > $1.addedAt }
        if matches.isEmpty {
            ContentUnavailableView {
                Label("No cards named “\(searchText)” in your tin", systemImage: "magnifyingglass")
            } description: {
                Text("This only searches cards you own — the Search tab covers the whole catalog.")
            }
        } else {
            ForEach(matches) { entry in
                Button { editingEntry = entry } label: {
                    CollectionEntryRow(
                        card: try? store.card(id: entry.cardId),
                        entry: entry,
                        dividerName: dividerName(entry),
                        value: GroupStats.entryValue(entry, price: model.prices[entry.cardId],
                                                     variants: model.variantsByCard[entry.cardId] ?? [],
                                                     conditions: model.conditionsByCard[entry.cardId] ?? []))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "Unfiled"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "Unfiled")
    }

    private func cardName(_ entry: CollectionEntry) -> String {
        if let cached = nameCache.names[entry.cardId] { return cached }
        let name = (try? store.card(id: entry.cardId))?.name ?? entry.cardId
        nameCache.names[entry.cardId] = name
        return name
    }

    private func wishlistLink(_ wants: WantsModel) -> some View {
        HStack {
            Image(systemName: "heart").foregroundStyle(.pink)
            Text("Wishlist")
            Spacer()
            Text("\(wants.wanted.count)").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .background(navLink(WantedRoute()))
    }
}

private extension View {
    /// Strip List chrome so riffle rows read as trays in the tin, not table cells.
    func tinRow() -> some View {
        self.listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// One divider of the tin: a full-width tray with its cards riffled in a spread (newest in
/// front, on the left) behind a colored index tab carrying the penned label.
struct TinRiffleRow: View {
    let name: String
    let color: Color
    let cards: [CardRecord]   // distinct, newest first
    let count: Int
    let value: Double

    private var overflow: Int { max(0, count - cards.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: -8) {
            tab
            tray
        }
    }

    private var tab: some View {
        Text(name)
            .font(.system(.caption, design: .serif).italic().weight(.semibold))
            .foregroundStyle(.black.opacity(0.65))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 4).padding(.bottom, 12)
            .background(color.gradient)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
            .padding(.leading, 12)
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer()
                Text("\(count) \(count == 1 ? "card" : "cards")")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(value, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
            }
            riffle
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    @ViewBuilder private var riffle: some View {
        if cards.isEmpty {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: 54, height: 75)
                Text("Nothing here yet").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .bottom, spacing: -28) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    CardImageView(card: card, quality: "low")
                        .frame(width: 56)
                        .rotationEffect(.degrees(i.isMultiple(of: 2) ? -1.5 : 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 1, y: 1)
                        .zIndex(Double(cards.count - i))   // newest (leftmost) stays on top
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.leading, 38)
                }
            }
        }
    }
}
