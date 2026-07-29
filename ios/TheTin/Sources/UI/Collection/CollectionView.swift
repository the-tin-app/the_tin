import SwiftUI
import Observation

@MainActor @Observable
final class CollectionModel {
    private let repository: CollectionRepository
    private let store: CatalogStore
    /// Portfolio-history model, app-lifetime so its series cache survives screen pushes.
    let portfolio: PortfolioModel
    private(set) var groups: [CardGroup] = []
    /// The cards you own. **Sold copies are filtered out of this**, which is what gives roughly
    /// forty consumers — GroupStats, Movers, PortfolioHistory, ScanKnowledge, set completion, the
    /// widget, every grid badge — the right answer without knowing the feature exists.
    private(set) var entries: [CollectionEntry] = [] {
        // Launch-tab signal: MainTabView reads this synchronously at init (the entries stream
        // hasn't delivered yet there) to open on The Tin once a collection exists.
        didSet { UserDefaults.standard.set(!entries.isEmpty, forKey: "hasCards") }
    }
    /// Every row the repository holds, owned and sold alike. Only for the places that genuinely
    /// mean "everything on file": whole-collection rewrites (undo) and CSV export. Using
    /// `entries` for either of those would silently drop every sold row from the file.
    private(set) var allEntries: [CollectionEntry] = []
    /// Copies that have left, most recently gone first.
    private(set) var soldEntries: [CollectionEntry] = []
    /// The sealed products you own, sold boxes filtered out — same owned/sold split as `entries`,
    /// made in the one place so no consumer has to remember it.
    private(set) var sealed: [SealedEntry] = []
    /// Every sealed row on file, owned and sold alike. Only for whole-collection rewrites (undo,
    /// backup) and CSV export, where dropping the sold rows would look like a successful save.
    private(set) var allSealed: [SealedEntry] = []
    /// tcgplayer_id → catalog product, for the sealed you own. Loaded only when there IS sealed:
    /// `allSealedProducts()` is a full table scan over ~2,500 rows, and a tin with no boxes must
    /// not pay for it on every entries-stream emission.
    private(set) var sealedProducts: [Int: SealedProduct] = [:]
    /// What the sealed you own is worth, in the same best-effort terms as `tinValue`.
    private(set) var sealedValue: (total: Double, priced: Int, boxes: Int) = (0, 0, 0)
    private(set) var prices: [String: PriceRecord] = [:]
    private(set) var variantsByCard: [String: [VariantPrice]] = [:]
    private(set) var conditionsByCard: [String: [ConditionPrice]] = [:]
    private(set) var matrixByCard: [String: [MatrixPrice]] = [:]
    private(set) var gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]
    private(set) var deltasByCard: [String: [DeltaRecord]] = [:]
    /// Derived value read-outs, recomputed once per entries/prices change instead of per access.
    /// Every one of these used to be a computed property, and every one was read from inside
    /// `body`: `CollectionView.groupRow` called `groupValue` for each divider on each body pass
    /// (an O(n) filter plus a full `GroupStats.totalValue` every time — 40 dividers over 5,000
    /// entries is 200k filter steps to draw one list), and `tradeLink` called `tradeEntries`,
    /// which SORTS the trade subset, purely to render its count. They change exactly when the
    /// entries stream fires or the catalog is swapped, which is where they're now computed.
    private(set) var valuesByGroup: [String: (total: Double, pricedCards: Int, totalCards: Int)] = [:]
    private(set) var tinValue: (total: Double, pricedCards: Int, totalCards: Int) = (0, 0, 0)
    /// Copies you've marked as available to trade, most valuable first — your spares are the
    /// currency of this hobby, and the app had no notion of them.
    private(set) var tradeEntries: [CollectionEntry] = []
    /// What the trade list is worth, in the same best-effort terms as the tin total.
    private(set) var tradeValue: (total: Double, pricedCards: Int, totalCards: Int) = (0, 0, 0)
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
            for await all in stream {
                // The one place the owned/sold split is made. Everything downstream reads a list
                // that is already correct, rather than each consumer remembering to exclude sold
                // rows — which is the version of this feature that would have quietly broken the
                // tin total the first time somebody added a screen.
                self?.allEntries = all
                self?.entries = all.filter { !$0.isSold }
                self?.soldEntries = all.filter(\.isSold).sorted {
                    ($0.soldAt ?? .distantPast) > ($1.soldAt ?? .distantPast)
                }
                self?.reloadPrices()
                self?.publishWidgetSnapshot()
            }
        })
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.repository.sealedStream() else { return }
            for await all in stream {
                self?.allSealed = all
                self?.sealed = all.filter { !$0.isSold }
                self?.reloadSealedProducts()
            }
        })
    }

    /// Re-read the catalog rows behind the sealed you own, then re-total. Skips the table scan
    /// entirely when there's no sealed — which is every tin that hasn't used the feature.
    private func reloadSealedProducts() {
        guard !sealed.isEmpty else {
            sealedProducts = [:]
            sealedValue = (0, 0, 0)
            return
        }
        let wanted = Set(sealed.map(\.productId))
        let all = (try? store.allSealedProducts()) ?? []
        sealedProducts = Dictionary(uniqueKeysWithValues:
            all.filter { wanted.contains($0.tcgplayerId) }.map { ($0.tcgplayerId, $0) })
        sealedValue = sealed.marketValue(products: sealedProducts)
    }

    /// The catalog artifact was swapped under the live store (daily update installed
    /// mid-session) — recompute everything cached from it.
    func catalogDidChange() {
        catalogGeneration += 1   // views keying caches (card names) off the catalog watch this
        reloadPrices()
        reloadSealedProducts()
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
        recomputeValues()
    }

    /// One bucketing pass over `entries`, then one `totalValue` per bucket — O(2n) for the whole
    /// screen, where per-divider `groupValue` calls were O(n × dividers).
    private func recomputeValues() {
        var byGroup: [String: [CollectionEntry]] = [:]
        for entry in entries { byGroup[entry.groupId, default: []].append(entry) }
        valuesByGroup = byGroup.mapValues { totalValue($0) }
        tinValue = totalValue(entries)
        let forTrade = entries.filter(\.isForTrade)
        tradeEntries = GroupStats.sortedByValueDescending(
            entries: forTrade, prices: prices,
            variantsByCard: variantsByCard, conditionsByCard: conditionsByCard,
            matrixByCard: matrixByCard, gradedByPrintingByCard: gradedByPrintingByCard)
        tradeValue = totalValue(forTrade)
    }

    /// `GroupStats.totalValue` with this model's price tables already threaded in.
    private func totalValue(_ entries: [CollectionEntry]) -> (total: Double, pricedCards: Int, totalCards: Int) {
        GroupStats.totalValue(entries: entries, prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard,
                              matrixByCard: matrixByCard, gradedByPrintingByCard: gradedByPrintingByCard)
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

    /// A divider's value. Served from `valuesByGroup`; a divider with no entries has no bucket
    /// and reads as zero, which is what an empty divider is worth.
    func groupValue(_ groupId: String) -> (total: Double, pricedCards: Int, totalCards: Int) {
        valuesByGroup[groupId] ?? (0, 0, 0)
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

    // MARK: Undo

    /// The last destructive change, kept just long enough to offer it back. Every delete dialog
    /// in the app said "this can't be undone" — and it couldn't, so one mis-swipe on a graded copy
    /// meant retyping the grade, the fee, the date and the shop it came from.
    struct UndoableDelete: Equatable, Identifiable {
        let id = UUID()
        /// "Removed Charizard ex" — what the toast says happened.
        let message: String
        let groups: [CardGroup]
        let entries: [CollectionEntry]
        /// When this offer lapses. Stamped by `offerUndo`, and carried on the offer rather than
        /// left to the toast so the countdown bar stays HONEST: SwiftUI can tear the toast down
        /// and rebuild it mid-window (the entries stream re-evaluates that subtree right after a
        /// delete — see `undoExpiry` below), and a view-owned timer would restart from full and
        /// promise time that isn't there. The deadline is the truth; the bar just reads it.
        var expiresAt: Date = .distantFuture
    }
    private(set) var undoable: UndoableDelete?

    /// Counts down the offer. Owned by the model, NOT by a `.task` on the toast view: SwiftUI
    /// cancels a view task whenever it tears the view down or re-identifies it, and the entries
    /// stream fires immediately after a delete — re-evaluating exactly that subtree. The cancelled
    /// `try? await Task.sleep` then swallowed its own CancellationError and fell straight through
    /// to the clear, so the offer was raised and wiped inside a frame and no toast was ever
    /// visible, at any placement. (Same trap `publishWidgetSnapshot` guards against, and the same
    /// "policy belongs in the model where a test can reach it" lesson as the scanner's auto-pause.)
    private var undoExpiry: Task<Void, Never>?

    /// How long an undo stays on offer.
    static let undoWindow: Duration = .seconds(6)
    /// The same window as a `TimeInterval`, for the toast's countdown bar. Derived, not a second
    /// literal — two numbers that must agree eventually stop agreeing.
    static var undoWindowSeconds: TimeInterval { TimeInterval(undoWindow.components.seconds) }

    func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        undoable = nil
    }

    /// Raise an undo offer and start its countdown, replacing any offer already standing.
    private func offerUndo(_ offer: UndoableDelete) {
        undoExpiry?.cancel()
        var offer = offer
        offer.expiresAt = Date().addingTimeInterval(Self.undoWindowSeconds)
        undoable = offer
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            // A cancelled sleep means a NEWER offer superseded this one (or someone took the
            // undo). Clearing here would wipe that newer offer — the exact bug this moved to fix.
            guard !Task.isCancelled else { return }
            self?.undoable = nil
            self?.undoExpiry = nil
        }
    }

    /// Put back exactly what was removed, ids and all, in one write. `replaceAll` is the only
    /// repository call that preserves ids (it exists for backup restore) — `createGroup`/`addEntry`
    /// would mint new ones, which would orphan the entries pointing at the old group id.
    func undoLastDelete() async {
        guard let undone = undoable else { return }
        undoExpiry?.cancel()
        undoExpiry = nil
        undoable = nil

        var restoredGroups = groups
        for group in undone.groups where !restoredGroups.contains(where: { $0.id == group.id }) {
            restoredGroups.append(group)
        }
        // The snapshot carries the original sortOrder, so a restored divider lands back in its
        // old position rather than at the end.
        restoredGroups.sort { $0.sortOrder < $1.sortOrder }

        // `allEntries`, NOT `entries`: this hands `replaceAll` the complete file. Built from the
        // sold-filtered list it would rewrite the collection without a single sold row in it —
        // pressing Undo would silently delete your entire sale history.
        var restoredEntries = allEntries
        for entry in undone.entries {
            // Overwrite rather than append when the row still exists: deleting a divider "keeping
            // its cards" leaves them behind with groupId "", and this is what files them back.
            if let i = restoredEntries.firstIndex(where: { $0.id == entry.id }) {
                restoredEntries[i] = entry
            } else {
                restoredEntries.append(entry)
            }
        }
        // `sealed` is passed through UNCHANGED. Undo only ever restores cards and dividers, but
        // `replaceAll` rewrites the whole file — omitting sealed here would make pressing Undo on
        // a deleted divider silently destroy every sealed product in the tin.
        await write("undo that") {
            try await repository.replaceAll(groups: restoredGroups, entries: restoredEntries,
                                            sealed: sealed)
        }
    }

    private func cardName(_ cardId: String) -> String {
        (try? store.card(id: cardId))?.name ?? "card"
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
        let group = groups.first { $0.id == id }
        // Snapshot BEFORE the write: with `keepingEntries` these rows survive with groupId "",
        // and the pre-delete copies are what remember which divider they belonged to.
        let affected = entries.filter { $0.groupId == id }
        let ok = await write("delete the divider") {
            try await repository.deleteGroup(id: id, keepingEntries: keepingEntries)
        }
        guard ok, let group else { return }
        let n = affected.cardCount
        offerUndo(UndoableDelete(
            message: keepingEntries || affected.isEmpty
                ? "Deleted “\(group.name)”"
                : "Deleted “\(group.name)” and \(n) \(n == 1 ? "card" : "cards")",
            groups: [group], entries: affected))
    }
    func reorderGroups(ids: [String]) async {
        await write("reorder the dividers") { try await repository.reorderGroups(orderedIds: ids) }
    }

    @discardableResult
    func saveEntry(_ entry: CollectionEntry) async -> Bool {
        // `allEntries`: a sold row edited from the Gone section is not in `entries`, and looking
        // there would send an existing id down the *add* path — minting a duplicate of a row that
        // already exists rather than updating it.
        if allEntries.contains(where: { $0.id == entry.id }) {
            await write("save the card") { try await repository.updateEntry(entry) }
        } else {
            await write("save the card") { try await addOrIncrement(entry) }
        }
    }

    /// The one place a *new* entry lands, so every add path behaves the same: an identical plain
    /// copy already in the tin gets its quantity bumped instead of gaining a second ×1 row it
    /// can't be told apart from (see `CollectionEntry.isSameCopy`). CSV import is deliberately
    /// not routed here — it's append-only into its own divider by design.
    private func addOrIncrement(_ entry: CollectionEntry) async throws {
        if var twin = entries.first(where: { $0.isSameCopy(as: entry) }) {
            twin.qty += entry.qty
            try await repository.updateEntry(twin)
        } else {
            try await repository.addEntry(entry)
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

    /// Refile many cards behind one divider in a single write — the answer to a CSV import that
    /// landed 500 cards in one place. Arrivals fold into an identical plain copy already there,
    /// exactly as a single add does (`CollectionEntry.isSameCopy`), so bulk refiling can't
    /// re-create the duplicate rows that rule exists to prevent.
    func moveEntries(ids: Set<String>, toGroup groupId: String) async {
        let moving = entries.filter { ids.contains($0.id) && $0.groupId != groupId }
        guard !moving.isEmpty else { return }
        // Rows already behind the destination divider, plus each arrival as it lands — so two
        // moved copies of the same card fold into each other, not just into a pre-existing row.
        var pool = entries.filter { $0.groupId == groupId && !ids.contains($0.id) }
        let quantityBefore = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.qty) })
        var deletedIds: [String] = []
        for var entry in moving {
            entry.groupId = groupId
            if let i = pool.firstIndex(where: { $0.isSameCopy(as: entry) }) {
                pool[i].qty += entry.qty
                deletedIds.append(entry.id)
            } else {
                pool.append(entry)
            }
        }
        // Write back arrivals (no prior quantity) and absorbers that grew; leave the rest alone.
        let updated = pool.filter { quantityBefore[$0.id] != $0.qty }
        await write("move the cards") {
            try await repository.applyEntryEdits(updated: updated, deletedIds: deletedIds)
        }
    }

    // MARK: Sold / traded away

    /// Record that a copy has gone. Not a delete: the row keeps its card, its condition, its
    /// cost basis and its acquisition detail, and stops counting toward what you own.
    ///
    /// Undoable through the same six-second toast as a delete, because the two gestures sit next
    /// to each other and one of them used to be the only option.
    func markSold(_ entry: CollectionEntry, on date: Date, for amount: Double?) async {
        var sold = entry
        sold.soldAt = date
        sold.soldFor = amount
        // The copy is gone, so it can't still be on offer — leaving the flag would keep it on a
        // trade list you'd bring to a meetup.
        sold.forTrade = nil
        let ok = await write("record that sale") { try await repository.updateEntry(sold) }
        guard ok else { return }
        offerUndo(UndoableDelete(message: "Marked \(cardName(entry.cardId)) as gone",
                                 groups: [], entries: [entry]))
    }

    /// Put a sold copy back among the cards you own — the sale fell through, or it was a mis-tap.
    func markUnsold(_ entry: CollectionEntry) async {
        var restored = entry
        restored.soldAt = nil
        restored.soldFor = nil
        await write("bring that card back") { try await repository.updateEntry(restored) }
    }

    func deleteEntry(id: String) async {
        // Sold rows are deletable too (from the Gone section), so look in the full list — else
        // the write lands but the undo offer never appears.
        let removed = allEntries.first { $0.id == id }
        let ok = await write("remove the card") { try await repository.deleteEntry(id: id) }
        guard ok, let removed else { return }
        offerUndo(UndoableDelete(message: "Removed \(cardName(removed.cardId))",
                                 groups: [], entries: [removed]))
    }

    // MARK: Sealed products

    /// Add or update a sealed product. `allSealed`, not `sealed`: editing a sold box from a future
    /// "gone" surface must route a known id to `updateSealed` rather than minting a duplicate.
    ///
    /// There is deliberately no add-or-increment twin rule here (`CollectionEntry.isSameCopy`).
    /// Sealed has no condition/grade/printing to compare, so "the same product twice" is just a
    /// quantity — which the form already asks for directly.
    @discardableResult
    func saveSealed(_ entry: SealedEntry) async -> Bool {
        if allSealed.contains(where: { $0.id == entry.id }) {
            return await write("save the sealed product") { try await repository.updateSealed(entry) }
        }
        return await write("save the sealed product") { try await repository.addSealed(entry) }
    }

    func deleteSealed(id: String) async {
        await write("remove the sealed product") { try await repository.deleteSealed(id: id) }
    }

    /// The catalog row behind a sealed entry, or nil when this catalog doesn't carry it (an older
    /// artifact, or a product that has since left the feed). Callers show the raw id rather than
    /// dropping the row — you still own the box.
    func sealedProduct(_ entry: SealedEntry) -> SealedProduct? { sealedProducts[entry.productId] }

    // MARK: Trade list

    /// Cards you hold more than one physical copy of. Marking is explicit by design, but an
    /// explicit-only feature opens on a blank screen forever — this is what the empty trade list
    /// offers to flag for you.
    var duplicateCardIds: Set<String> {
        var qtyByCard: [String: Int] = [:]
        for entry in entries { qtyByCard[entry.cardId, default: 0] += entry.qty }
        return Set(qtyByCard.filter { $0.value > 1 }.keys)
    }

    func setForTrade(_ entry: CollectionEntry, _ on: Bool) async {
        var updated = entry
        updated.forTrade = on ? true : nil   // nil, not false — keeps untouched entries clean
        await saveEntry(updated)
    }

    /// Flag every copy of every card you hold more than once — as INDIVIDUAL rows, in one write.
    ///
    /// A ×4 row becomes four ×1 rows, because trading is a per-copy decision: you keep the sharp
    /// one and trade the other three, and each may be in a different condition. Flagging the stack
    /// as a unit couldn't express that. Any money recorded on the row is a total (the form says
    /// "Price paid — total"), so it divides across the copies and the cost basis survives the
    /// split.
    func flagDuplicatesForTrade() async {
        let duplicates = duplicateCardIds
        var updated: [CollectionEntry] = []
        for entry in entries where duplicates.contains(entry.cardId) {
            guard entry.qty > 1 else {
                if !entry.isForTrade {
                    var one = entry
                    one.forTrade = true
                    updated.append(one)
                }
                continue
            }
            let share = { (total: Double?) in total.map { $0 / Double(entry.qty) } }
            for copy in 0..<entry.qty {
                var one = entry
                // The first copy keeps the original row's id, so an undo or a backup that
                // references it still resolves; the rest are new rows.
                one.id = copy == 0 ? entry.id : UUID().uuidString
                one.qty = 1
                one.forTrade = true
                one.pricePaid = share(entry.pricePaid)
                one.gradingFeeUsd = share(entry.gradingFeeUsd)
                updated.append(one)
            }
        }
        guard !updated.isEmpty else { return }
        await write("update your trade list") {
            try await repository.applyEntryEdits(updated: updated, deletedIds: [])
        }
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
                                    variant: draft.variant.rawValue,
                                    acquiredVia: draft.acquiredVia?.rawValue)
        // Same merge rule as every other add path, but this one keeps its own error handling:
        // the review screen re-presents the failure and keeps the draft, so `write`'s global
        // alert would double up on it.
        do { try await addOrIncrement(entry); return true }
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
    /// cardId → record, including misses (a `nil` value is a cached "not in this catalog", so a
    /// missing card isn't re-queried on every pass). Double-optional subscript is deliberate.
    private var cards: [String: CardRecord?] = [:]

    /// The catalog record for a card, cached. `CollectionView.riffleCards` spreads up to seven
    /// cards per divider and re-ran this query for every one of them on every body pass — ~280
    /// SQLite reads to draw a 40-divider tin.
    func card(id cardId: String, store: CatalogStore) -> CardRecord? {
        if let cached = cards[cardId] { return cached }
        let record = try? store.card(id: cardId)
        cards[cardId] = record
        return record
    }

    func name(for entry: CollectionEntry, store: CatalogStore) -> String {
        if let cached = names[entry.cardId] { return cached }
        let name = card(id: entry.cardId, store: store)?.name ?? entry.cardId
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
        if let card = card(id: entry.cardId, store: store) {
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
        cards.removeAll()
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
    /// Scanner pack already installed — flips the empty-tin CTA from "set up" to "scan".
    var scannerReady = false
    /// Hands the current query to the catalog-wide Search tab. Without it, searching your tin for
    /// something you don't own dead-ended in a note pointing at another tab — the app admitting a
    /// seam instead of crossing it.
    var onSearchCatalog: ((String) -> Void)? = nil
    /// The sets being collected — drives the Wanted screen's Sets segment.
    var goals: SetGoalsModel? = nil
    /// Pushes a stack's flip-through deck (nil = the whole tin). VoiceOver's custom-action
    /// mirror of the context menu's "Flip through cards" — actions can't tap the invisible
    /// NavigationLinks. (Row activation itself opens the list-first landing.)
    var openPager: ((String?) -> Void)? = nil
    /// Opens the settings sheet, which the host owns.
    ///
    /// The gear used to be a SECOND `.toolbar` applied by `RootView` over this view. On iPadOS 18
    /// that combination silently dropped it: the trailing items collapsed into a system overflow
    /// and the separately-declared item never made it in, so Settings — and with it export,
    /// import and backup restore — was unreachable on iPad (reported 2026-07-27). One toolbar,
    /// one set of explicit placements, no merge to get wrong.
    var onOpenSettings: (() -> Void)? = nil
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var renamingGroupId: String?
    @State private var renameGroupName = ""
    @State private var editMode: EditMode = .inactive
    @State private var printRequest: PrintSheetRequest?
    @State private var showingReport = false
    @State private var deletingGroup: CardGroup?
    /// Second-stage confirmation for the one action that destroys cards rather than just a
    /// divider. Set only from the first alert's destructive button.
    @State private var destroyingGroup: CardGroup?
    @State private var searchText = ""
    @State private var editingEntry: CollectionEntry?
    @State private var editingSealed: SealedEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchIndex = CardSearchIndex()

    /// How many cards a riffle row spreads before collapsing into "+N".
    private static let riffleLimit = 7

    var body: some View {
        List {
            if searchText.isEmpty {
                if model.catalogUnavailable { catalogNotice.tinRow() }
                if model.entries.isEmpty {
                    // A first-run tin has nothing to total, riffle, or file — so the screen's job
                    // is to say what a tin is and offer the two ways to fill it. Dividers still
                    // show if any exist (deleting the last card mustn't strand them), and the
                    // wishlist only when it has something in it.
                    emptyTin.tinRow()
                    ForEach(model.groups) { group in
                        groupRow(group).tinRow()
                    }
                    // Also on the empty branch: a tin holding only sealed products owns no CARDS,
                    // which is what this branch is about — but it isn't empty, and hiding what
                    // you do own behind a "your tin is empty" screen would read as data loss.
                    sealedSection
                    if let wants, !wants.wanted.isEmpty { wishlistLink(wants).tinRow() }
                } else {
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
                    sealedSection
                    if let wants { wishlistLink(wants).tinRow() }
                    // Not on the empty branch: with no entries there is nothing to trade, so the
                    // row would only be a promise the tin can't keep — same rule as the wishlist.
                    tradeLink.tinRow()
                }
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
        // ONE toolbar for this screen, every item explicitly placed. Items used to arrive from two
        // separate `.toolbar` modifiers — these, plus a gear applied by `RootView` — and on
        // iPadOS 18 the gear was dropped rather than collapsed, stranding Settings.
        .toolbar {
            if model.groups.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let next: EditMode = editMode == .active ? .inactive : .active
                        if reduceMotion { editMode = next } else { withAnimation { editMode = next } }
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                    }
                    .accessibilityLabel(editMode == .active ? "Done reordering" : "Reorder dividers")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Settings lives HERE, not only on the gear below.
                    //
                    // On iPadOS 18 a third trailing item is silently dropped — not collapsed into
                    // the overflow, dropped — so the gear never rendered and Settings (and with it
                    // export, import and backup restore) was unreachable on iPad entirely.
                    // Consolidating into one toolbar with explicit placements did NOT fix it;
                    // this is the second attempt, and it takes the route that cannot fail: menu
                    // contents are never subject to toolbar overflow. The gear stays for iPhone,
                    // where it renders fine and is the more discoverable affordance.
                    if let onOpenSettings {
                        Button(action: onOpenSettings) {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                    Button { showingReport = true }
                        label: { Label("Collection report (PDF)", systemImage: "doc.text") }
                        .disabled(model.entries.isEmpty)
                } label: {
                    // A Label, not a bare Image: when iPadOS folds this into its overflow menu it
                    // renders the label as TEXT, and an image-only label became a blank row you
                    // had to tap on faith to find the report underneath.
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
            if let onOpenSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
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
        // An ALERT, not a confirmationDialog. On iPad the dialog renders as a popover with no
        // anchor, so it appeared at the top of the screen — nowhere near the row you swiped —
        // and the choice you hadn't noticed was the one you didn't take (reported 2026-07-27).
        // Alerts are centred and identical on both platforms.
        .alert("Delete “\(deletingGroup?.name ?? "")”?",
               isPresented: Binding(get: { deletingGroup != nil },
                                    set: { if !$0 { deletingGroup = nil } }),
               presenting: deletingGroup) { group in
            let n = model.entries(in: group.id).cardCount
            if n > 0 {
                Button("Keep \(n == 1 ? "the card" : "the \(n) cards")") {
                    Task { await model.deleteGroup(id: group.id, keepingEntries: true) }
                }
                // Hands off to a second alert rather than deleting here. Losing cards is not the
                // same kind of act as losing a divider, and it shouldn't cost the same one tap.
                Button("Delete \(n == 1 ? "card" : "cards") too", role: .destructive) {
                    destroyingGroup = group
                }
            } else {
                Button("Delete divider", role: .destructive) {
                    Task { await model.deleteGroup(id: group.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            let n = model.entries(in: group.id).cardCount
            Text(n == 0 ? "This divider is empty."
                        : "\(n == 1 ? "1 card is" : "\(n) cards are") filed here. Keeping \(n == 1 ? "it moves it" : "them moves them") to No divider.")
        }
        // Step two, and the only place cards are actually destroyed. Named counts on purpose: the
        // number is the thing you're about to lose, so it belongs in the title, not the body.
        .alert("Delete \(model.entries(in: destroyingGroup?.id ?? "").cardCount) \(model.entries(in: destroyingGroup?.id ?? "").cardCount == 1 ? "card" : "cards") permanently?",
               isPresented: Binding(get: { destroyingGroup != nil },
                                    set: { if !$0 { destroyingGroup = nil } }),
               presenting: destroyingGroup) { group in
            Button("Delete", role: .destructive) {
                Task { await model.deleteGroup(id: group.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the cards from your tin, not just the divider. You'll get a moment to undo it.")
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
            if let wants {
                WantedView(store: store, wants: wants, collection: model, goals: goals)
            }
        }
        .navigationDestination(for: TradeRoute.self) { _ in
            TradeListView(model: model, store: store)
        }
        .navigationDestination(for: TinAllCardsRoute.self) { _ in
            GroupDetailView(model: model, group: nil, store: store, onGetStarted: onGetStarted)
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
        .sheet(item: $editingSealed) { entry in
            if let product = model.sealedProduct(entry) {
                NavigationStack {
                    SealedEntryFormView(product: product, existing: entry) {
                        await model.saveSealed($0)
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

    /// Only rendered once there's a card to total — `emptyTin` owns the first-run screen.
    private var header: some View {
        let v = model.tinValue
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(v.total, format: WidgetShared.tinCurrency(v.total))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .background { navLink(PortfolioRoute()) }
            .accessibilityLabel("Tin value, \(v.total.formatted(.currency(code: "USD").precision(.fractionLength(0))))")
            .accessibilityHint("Shows portfolio value history")
            Text("\(v.totalCards) cards in your tin · \(v.pricedCards) of \(v.totalCards) priced")
                .font(.footnote).foregroundStyle(.secondary)
            if let asOf = model.priceAsOf {
                AsOfLabel(date: asOf)
            }
        }
        .padding(.bottom, 6)
    }

    /// First run: say what a tin is, then the two ways to put a card in one. The scanner option
    /// names its one-time download up front (it's ~half a gig) so tapping through isn't a
    /// surprise — and drops the download line once the pack is installed.
    private var emptyTin: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44)).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Your tin is empty")
                    .font(.system(.title2, design: .serif).italic().weight(.semibold))
                Text("A tin holds the cards you own — what each one is worth today, and how that value moves. File them behind dividers however you like.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 14) {
                getStartedOption(
                    title: scannerReady ? "Scan a card" : "Set up the scanner",
                    caption: scannerReady
                        ? "Point your camera at a card and The Tin names it."
                        : "One-time download, then your camera names any card.",
                    prominent: true) { onGetStarted?(.scan) }
                getStartedOption(
                    title: "Browse sets",
                    caption: "Pick a set, find the card, add it by hand.",
                    prominent: false) { onGetStarted?(.browse) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 8)
    }

    private func getStartedOption(title: String, caption: String, prominent: Bool,
                                  action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(prominent ? .accentColor : Color(.secondarySystemFill))
                .foregroundStyle(prominent ? Color.white : Color.primary)
            // The button's intrinsic width otherwise stretches the stack and truncates this
            // to one clipped line instead of wrapping.
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
                // Tinted, NOT `role: .destructive`. The role makes SwiftUI animate the row out
                // the instant you tap — as if it were already gone — and the row then springs
                // back when the confirmation appears, so the list showed a deletion that hadn't
                // happened yet (reported 2026-07-27). Nothing here deletes without confirming.
                Button { deletingGroup = group }
                    label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
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

    /// The distinct cards a row spreads, newest first. Reads through `searchIndex`'s card cache —
    /// this runs for every divider on every body pass, so uncached it was the single biggest
    /// source of SQLite traffic on the tin's landing screen.
    private func riffleCards(_ entries: [CollectionEntry]) -> [CardRecord] {
        var seen = Set<String>()
        var out: [CardRecord] = []
        for e in entries where seen.insert(e.cardId).inserted {
            if let c = searchIndex.card(id: e.cardId, store: store) { out.append(c) }
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

    /// Sealed products you own, as a section beside the dividers. Rendered straight into the List
    /// (not wrapped in a container) so each row keeps its own swipe actions.
    ///
    /// Hidden entirely when empty — an empty section advertising a feature you aren't using is
    /// noise, and sealed is a feature most collectors will never touch.
    @ViewBuilder private var sealedSection: some View {
        if !model.sealed.isEmpty {
            SealedSectionHeader(value: model.sealedValue).tinRow()
            ForEach(model.sealed) { entry in
                SealedRow(entry: entry, product: model.sealedProduct(entry))
                    .tinRow()
                    .contentShape(Rectangle())
                    .onTapGesture { editingSealed = entry }
                    // Reveal-then-tap IS the confirmation, and no full swipe, so it can't fire by
                    // accident — the same rule the tin's card rows follow.
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Remove", role: .destructive) {
                            Task { await model.deleteSealed(id: entry.id) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { editingSealed = entry } label: { Label("Edit", systemImage: "pencil") }
                    }
                    .accessibilityAction(named: "Edit") { editingSealed = entry }
                    .accessibilityAction(named: "Remove") {
                        Task { await model.deleteSealed(id: entry.id) }
                    }
            }
        }
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
                Text("This searches the cards you own, by name, set, and number.")
            } actions: {
                if let onSearchCatalog {
                    Button("Search the whole catalog") { onSearchCatalog(searchText) }
                        .buttonStyle(.borderedProminent)
                }
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
                // Reveal-then-tap IS the confirmation (Notes/Reminders): a dialog after the swipe
                // made the row vanish, come back, and ask again. No full swipe, so it can't fire
                // by accident.
                .swipeActions(allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) {
                        Task { await model.deleteEntry(id: entry.id) }
                    }
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
        // One row for both kinds of wanting: sets you're collecting and singles you're hunting.
        pinnedLink(title: "Wanted", systemImage: "heart", tint: .pink,
                   count: wants.wanted.count + (goals?.setIds.count ?? 0), route: WantedRoute())
    }

    /// The other half of the wishlist: what you'll give up. Sits beside it because "hunting" and
    /// "trading" are the same conversation at a meetup.
    private var tradeLink: some View {
        pinnedLink(title: "For Trade", systemImage: "arrow.left.arrow.right", tint: .orange,
                   count: model.tradeEntries.count, route: TradeRoute())
    }

    /// The pinned rows under the dividers — same shape, so they read as a pair.
    private func pinnedLink<V: Hashable>(title: String, systemImage: String, tint: Color,
                                         count: Int, route: V) -> some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .background(navLink(route))
    }
}

private extension View {
    /// Strip List chrome so riffle rows read as trays in the tin, not table cells.
    ///
    /// Capped and re-centred, the same way card detail caps its art. Uncapped, an iPad stretches
    /// every tray to ~1000pt while the card spread still occupies ~220pt of it — a very wide,
    /// mostly empty box with the count and value stranded at the far right. 700 never binds on
    /// iPhone: the widest content width we ship is ~408pt on the 17 Pro Max.
    /// `alignment: .leading` on the inner frame is load-bearing. `.frame(maxWidth:)` centres its
    /// content by default, so capping the header — a `VStack(alignment: .leading)` narrower than
    /// the row — silently centred the tin total and shifted it right of where it had always sat.
    /// Rows whose content already fills the width (the riffle trays, the pinned links) don't
    /// notice either way.
    func tinRow() -> some View {
        self.frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
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
