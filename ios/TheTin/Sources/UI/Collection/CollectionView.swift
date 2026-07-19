import SwiftUI
import Observation

@MainActor @Observable
final class CollectionModel {
    private let repository: CollectionRepository
    private let store: CatalogStore
    /// Portfolio-history model, app-lifetime so its series cache survives screen pushes.
    let portfolio: PortfolioModel
    private(set) var groups: [CardGroup] = []
    private(set) var entries: [CollectionEntry] = [] {
        // Launch-tab signal: MainTabView reads this synchronously at init (the entries stream
        // hasn't delivered yet there) to open on The Tin once a collection exists.
        didSet { UserDefaults.standard.set(!entries.isEmpty, forKey: "hasCards") }
    }
    private(set) var prices: [String: PriceRecord] = [:]
    private(set) var variantsByCard: [String: [VariantPrice]] = [:]
    private(set) var conditionsByCard: [String: [ConditionPrice]] = [:]
    private(set) var matrixByCard: [String: [MatrixPrice]] = [:]
    private(set) var gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]
    private(set) var deltasByCard: [String: [DeltaRecord]] = [:]
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
        catalogGeneration += 1   // views keying caches (card names) off the catalog watch this
        reloadPrices()
        publishWidgetSnapshot()
    }
    private(set) var catalogGeneration = 0

    /// True when the catalog store can't be read (corrupt/missing DB) — the single honest
    /// signal for the ~26 silently-degrading `try?` catalog reads across collection views:
    /// every read funnels through the same store, so if prices fail here, names fail there.
    private(set) var catalogUnavailable = false

    private func reloadPrices() {
        let ids = Array(Set(entries.map(\.cardId)))
        // The base price read is the health signal; variant/condition reads may legitimately
        // come up empty on minimal catalogs and still degrade per-call.
        do {
            prices = try store.prices(cardIds: ids)
            catalogUnavailable = false
        } catch {
            prices = [:]
            catalogUnavailable = true
        }
        variantsByCard = (try? store.variantPrices(cardIds: ids)) ?? [:]
        conditionsByCard = (try? store.conditionPrices(cardIds: ids)) ?? [:]
        matrixByCard = (try? store.matrixPrices(cardIds: ids)) ?? [:]
        gradedByPrintingByCard = (try? store.gradedPrintingPrices(cardIds: ids)) ?? [:]
        deltasByCard = (try? store.deltas(cardIds: ids)) ?? [:]
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
        let matrix = matrixByCard[entry.cardId] ?? []
        let gradedByPrinting = gradedByPrintingByCard[entry.cardId] ?? []
        guard GroupStats.isPricedExactly(entry, price: prices[entry.cardId], variants: variants, conditions: conditions,
                                         matrix: matrix, gradedByPrinting: gradedByPrinting)
        else { return nil }
        return GroupStats.entryValue(entry, price: prices[entry.cardId], variants: variants, conditions: conditions,
                                     matrix: matrix, gradedByPrinting: gradedByPrinting)
    }

    func groupValue(_ groupId: String) -> (total: Double, pricedCards: Int, totalCards: Int) {
        GroupStats.totalValue(entries: entries(in: groupId), prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard,
                              matrixByCard: matrixByCard, gradedByPrintingByCard: gradedByPrintingByCard)
    }

    /// The whole tin's value across every group and ungrouped card.
    var tinValue: (total: Double, pricedCards: Int, totalCards: Int) {
        GroupStats.totalValue(entries: entries, prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard,
                              matrixByCard: matrixByCard, gradedByPrintingByCard: gradedByPrintingByCard)
    }

    /// The catalog's price date — prices always carry their as-of stamp (Caption Ledger Rule).
    var priceAsOf: String? { try? store.priceAsOf() }

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
        let matrixByCard = self.matrixByCard
        let gradedByPrintingByCard = self.gradedByPrintingByCard
        let asOf = prices.values.map(\.asOf).max()   // "yyyy-MM-dd" sorts lexicographically
        let store = self.store   // @unchecked Sendable — safe to hand to a detached task
        widgetSnapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let ids = Array(Set(entries.map(\.cardId)))
            let histories = (try? store.priceHistory(cardIds: ids)) ?? [:]
            let series = PortfolioHistory.series(entries: entries, histories: histories,
                                                 prices: prices, variantsByCard: variantsByCard,
                                                 conditionsByCard: conditionsByCard,
                                                 matrixByCard: matrixByCard,
                                                 gradedByPrintingByCard: gradedByPrintingByCard)
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
    func deleteGroup(id: String, keepingEntries: Bool = false) async {
        await write("delete the divider") { try await repository.deleteGroup(id: id, keepingEntries: keepingEntries) }
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

/// cardId → searchable text ("name · set name · set id · number"), filled lazily while
/// filtering so a search over 800 entries doesn't re-query the catalog per keystroke.
/// A reference type so filling it during body evaluation isn't a state mutation.
/// Shared by CollectionView and GroupDetailView; cleared on catalog swap.
final class CardSearchIndex {
    private var haystacks: [String: String] = [:]
    private var names: [String: String] = [:]

    func name(for entry: CollectionEntry, store: CatalogStore) -> String {
        if let cached = names[entry.cardId] { return cached }
        let name = (try? store.card(id: entry.cardId))?.name ?? entry.cardId
        names[entry.cardId] = name
        return name
    }

    /// Every query token must appear somewhere in the haystack, so "151", "swsh7 215",
    /// and "brilliant stars charizard" all land.
    func matches(_ entry: CollectionEntry, query: String, store: CatalogStore) -> Bool {
        Self.tokenMatch(haystack: haystack(for: entry, store: store), query: query)
    }

    static func tokenMatch(haystack: String, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace)
            .allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func haystack(for entry: CollectionEntry, store: CatalogStore) -> String {
        if let cached = haystacks[entry.cardId] { return cached }
        var parts = [entry.cardId]
        if let card = try? store.card(id: entry.cardId) {
            parts.append(contentsOf: [card.name, card.setId, card.number])
            if let set = try? store.set(id: card.setId) { parts.append(set.name) }
        }
        let hay = parts.joined(separator: " ")
        haystacks[entry.cardId] = hay
        return hay
    }

    func clear() {
        haystacks.removeAll()
        names.removeAll()
    }
}

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
    /// Where the empty-tin call-to-action routes; the host (MainTabView) switches tabs.
    enum GetStartedTab { case scan, browse }

    @Bindable var model: CollectionModel
    let store: CatalogStore
    var wants: WantsModel? = nil
    var onGetStarted: ((GetStartedTab) -> Void)? = nil
    /// Pushes a stack's flip-through deck (nil = the whole tin). VoiceOver's custom-action
    /// mirror of the context menu's "Flip through cards" — actions can't tap the invisible
    /// NavigationLinks. (Row activation itself opens the list-first landing.)
    var openPager: ((String?) -> Void)? = nil
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
    @State private var deletingEntry: CollectionEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchIndex = CardSearchIndex()

    /// How many cards a riffle row spreads before collapsing into "+N".
    private static let riffleLimit = 7

    var body: some View {
        List {
            if searchText.isEmpty {
                if model.catalogUnavailable { catalogNotice.tinRow() }
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
        .searchable(text: $searchText, prompt: "Search by name, set, or number")
        .environment(\.editMode, $editMode)
        .printSheetFlow($printRequest)
        .collectionReportFlow(isActive: $showingReport, collection: model, store: store)
        .navigationTitle("The Tin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.groups.count > 1 {
                Button {
                    let next: EditMode = editMode == .active ? .inactive : .active
                    if reduceMotion { editMode = next } else { withAnimation { editMode = next } }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
                .accessibilityLabel(editMode == .active ? "Done reordering" : "Reorder dividers")
            }
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
            if n > 0 {
                Button("Delete divider, keep \(n == 1 ? "its card" : "its \(n) cards")") {
                    Task { await model.deleteGroup(id: group.id, keepingEntries: true) }
                }
            }
            Button(n == 0 ? "Delete divider" : "Delete divider and \(n) \(n == 1 ? "card" : "cards")",
                   role: .destructive) {
                Task { await model.deleteGroup(id: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            let n = model.entries(in: group.id).cardCount
            Text(n == 0 ? "This divider is empty."
                        : "Kept \(n == 1 ? "card moves" : "cards move") to No divider. Deleting \(n == 1 ? "it" : "them") too can't be undone.")
        }
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
        .navigationDestination(for: TinPagerRoute.self) { route in
            GroupPagerView(model: model, store: store, groupId: route.groupId)
        }
        .navigationDestination(for: PortfolioRoute.self) { route in
            PortfolioView(model: model, groupId: route.groupId)
        }
        .navigationDestination(for: String.self) { groupId in
            if let group = model.groups.first(where: { $0.id == groupId }) {
                GroupDetailView(model: model, group: group, store: store, onGetStarted: onGetStarted)
            }
        }
        .navigationDestination(for: WantedRoute.self) { _ in
            if let wants { WantedCardsView(store: store, wants: wants, collection: model) }
        }
        .navigationDestination(for: TinAllCardsRoute.self) { _ in
            GroupDetailView(model: model, group: nil, store: store, onGetStarted: onGetStarted)
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
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card, history: CatalogPriceHistory(store: store)),
                               store: store, collection: model, wants: wants)
            }
        }
        .onChange(of: model.catalogGeneration) { searchIndex.clear() }
    }

    private var header: some View {
        let v = model.tinValue
        let isEmpty = model.entries.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(v.total, format: WidgetShared.tinCurrency(v.total))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                // An empty tin's "$0 ›" led to a screen that just said "add cards" —
                // no chevron, no route until there's a portfolio to show.
                if !isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .background { if !isEmpty { navLink(PortfolioRoute()) } }
            .accessibilityLabel("Tin value, \(v.total.formatted(.currency(code: "USD").precision(.fractionLength(0))))")
            .accessibilityHint(isEmpty ? "" : "Shows portfolio value history")
            if isEmpty {
                Text("Your tin is empty — add your first card.")
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
                .padding(.top, 6)
            } else {
                Text("\(v.totalCards) cards in your tin · \(v.pricedCards) of \(v.totalCards) priced")
                    .font(.footnote).foregroundStyle(.secondary)
                if let asOf = model.priceAsOf {
                    AsOfLabel(date: asOf)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var everythingRow: some View {
        let entries = model.allOwnedEntries
        return TinRiffleRow(name: "Everything", color: DividerPalette.steel,
                            cards: riffleCards(entries), count: entries.cardCount,
                            value: model.tinValue.total)
            .background(navLink(TinAllCardsRoute()))
            .contextMenu {
                NavigationLink(value: TinPagerRoute(groupId: nil)) {
                    Label("Flip through cards", systemImage: "rectangle.stack")
                }
            }
            .accessibilityAction(named: "Flip through cards") { openPager?(nil) }
    }

    private func groupRow(_ group: CardGroup) -> some View {
        let entries = model.entries(in: group.id).sorted { $0.addedAt > $1.addedAt }
        return TinRiffleRow(name: group.name, color: DividerPalette.color(for: group.id),
                            cards: riffleCards(entries), count: entries.cardCount,
                            value: model.groupValue(group.id).total)
            .background(navLink(group.id))
            .contextMenu {
                Button { renameGroupName = group.name; renamingGroupId = group.id }
                    label: { Label("Rename", systemImage: "pencil") }
                NavigationLink(value: TinPagerRoute(groupId: group.id)) {
                    Label("Flip through cards", systemImage: "rectangle.stack")
                }
                Button { printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store) }
                    label: { Label("Print sheet…", systemImage: "printer") }
                    .disabled(model.entries(in: group.id).isEmpty)
                Button(role: .destructive) { deletingGroup = group }
                    label: { Label("Delete divider", systemImage: "trash") }
            }
            // The context menu is invisible until long-pressed; swipe actions are the
            // discoverable path to the same Rename/Delete (delete still confirms).
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deletingGroup = group }
                    label: { Label("Delete", systemImage: "trash") }
                Button { renameGroupName = group.name; renamingGroupId = group.id }
                    label: { Label("Rename", systemImage: "pencil") }
            }
            // The riffle row is one flattened VoiceOver element, so the context-menu/swipe
            // actions need explicit mirrors (activate = open, as sighted tap).
            .accessibilityAction(named: "Rename") {
                renameGroupName = group.name; renamingGroupId = group.id
            }
            .accessibilityAction(named: "Flip through cards") { openPager?(group.id) }
            .accessibilityAction(named: "Print sheet") {
                if !entries.isEmpty {
                    printRequest = PrintSheet.tradeRequest(group: group, model: model, store: store)
                }
            }
            .accessibilityAction(named: "Delete divider") { deletingGroup = group }
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

    /// Honest degraded state when the catalog store can't be read: without it, names fall
    /// back to raw card ids and prices just vanish, which reads as data loss. Same visual
    /// pattern as PortfolioView's history notice.
    private var catalogNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't read the card catalog", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.medium))
            Text("Card names and prices can't be shown right now — your collection itself is safe. Restart the app, or re-download the catalog in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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

    /// Whole-tin search: "do I own this?" answered from the Tin root — a card-shop moment,
    /// so tap shows the card (art + price); editing is the deliberate second gesture
    /// (leading swipe / context menu). Rows carry the divider the copy lives behind.
    @ViewBuilder private var searchResults: some View {
        let matches = model.entries
            .filter { searchIndex.matches($0, query: searchText, store: store) }
            .sorted { $0.addedAt > $1.addedAt }
        if matches.isEmpty {
            ContentUnavailableView {
                Label("No matches for “\(searchText)” in your tin", systemImage: "magnifyingglass")
            } description: {
                Text("Searches cards you own by name, set, and number — the Search tab covers the whole catalog.")
            }
        } else {
            ForEach(matches) { entry in
                NavigationLink(value: CardID(raw: entry.cardId)) {
                    CollectionEntryRow(
                        card: try? store.card(id: entry.cardId),
                        entry: entry,
                        dividerName: dividerName(entry),
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
        }
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "No divider"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "No divider")
    }

    private func cardName(_ entry: CollectionEntry) -> String {
        searchIndex.name(for: entry, store: store)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) \(count == 1 ? "card" : "cards"), \(value.formatted(.currency(code: "USD").precision(.fractionLength(0))))")
        .accessibilityAddTraits(.isButton)
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
                    .monospacedDigit()
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
