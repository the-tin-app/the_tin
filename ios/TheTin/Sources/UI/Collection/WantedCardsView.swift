import SwiftUI
import UniformTypeIdentifiers

/// Grid of the user's wanted cards, resolved from the offline catalog by id. Reached only via
/// `WantedRoute`. Sort/search/group + per-card priority/target/notes signals.
struct WantedCardsView: View {
    let store: CatalogStore
    let wants: WantsModel
    var collection: CollectionModel? = nil
    /// Sets being collected — a single that's also covered by one gets a badge so it doesn't read
    /// as a duplicate of the set goal.
    var goals: SetGoalsModel? = nil

    @State private var sort: WishlistSort = .priority
    @State private var search = ""
    @State private var groupBySet = false
    @State private var priorityFilter: WantPriority? = nil   // nil = All priorities
    @State private var editing: CardRecord?
    @State private var printRequest: PrintSheetRequest?
    @State private var exportDoc: CSVDocument?
    @State private var exportName = "the-tin-wishlist"
    /// Rebuilt when the wishlist changes rather than per body pass — see `TradeListView`.
    @State private var shareLink: (url: URL, included: Int)?
    @State private var sharing: SharePayload?

    // `.top` so a tile that carries the "In a set you collect" caption doesn't force a blank
    // reserved line onto every tile that doesn't — see the note in `SetsListView`.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12, alignment: .top)]

    /// Bundles every store-backed read the screen needs. `fileprivate` so `WishlistCatalog`
    /// (below) can hold one; the view still refers to it unqualified.
    fileprivate struct Resolved {
        var allCards: [CardRecord] = []
        var priceRecords: [String: PriceRecord] = [:]
        var rawUsd: [String: Double] = [:]
        var setsById: [String: SetRecord] = [:]
    }

    /// The catalog reads, cached between body passes. This used to be a computed property called
    /// on the first line of `body` — so a `.searchable` screen re-ran `store.cards`,
    /// `store.prices` AND `store.sets()` (every set in the catalog) on every keystroke, over a
    /// wishlist that can hold hundreds of cards.
    @State private var catalog = WishlistCatalog()

    /// Effective priority of a wanted card — a bare-hearted card (no entry) is Normal.
    private func priority(_ id: String) -> WantPriority { wants.entries[id]?.priority ?? .normal }

    /// Search filter → priority filter → chosen sort.
    private func displayed(_ r: Resolved) -> [CardRecord] {
        var base = search.isEmpty ? r.allCards
            : r.allCards.filter { $0.name.localizedCaseInsensitiveContains(search) }
        if let pf = priorityFilter { base = base.filter { priority($0.id) == pf } }
        return WishlistGrid.sorted(cards: base, entries: wants.entries, prices: r.rawUsd,
                                   setDates: r.setsById.mapValues { $0.releaseDate ?? "" }, by: sort)
    }

    private func totalUsd(_ r: Resolved) -> Double {
        r.allCards.compactMap { r.rawUsd[$0.id] }.reduce(0, +)
    }
    private func atTargetCount(_ r: Resolved) -> Int {
        r.allCards.filter { WishlistGrid.isOnSale($0, entry: wants.entry($0.id), price: r.rawUsd[$0.id]) }.count
    }

    var body: some View {
        let r = catalog.resolve(wanted: wants.wanted, store: store)
        let displayedCards = displayed(r)
        Group {
            if r.allCards.isEmpty {
                ContentUnavailableView {
                    Label { Text("Your wishlist is empty") }
                    icon: { Image(systemName: "heart").foregroundStyle(.pink) }
                } description: {
                    Text("Tap the heart on any card to start hunting for it here.")
                }
            } else {
                ScrollView { content(r, displayedCards) }
            }
        }
        .navigationTitle("Wishlist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search wishlist")
        .toolbar {
            sortMenu(disabled: r.allCards.isEmpty)
            shareMenu(r: r, disabled: r.allCards.isEmpty)
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil },
                                           set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .commaSeparatedText,
                      defaultFilename: CollectionCSV.filename(exportName)) { _ in
            exportDoc = nil
        }
        .printSheetFlow($printRequest)
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        // A new catalog artifact can rename a set or reprice every card, and the cache keys off
        // the wishlist alone — so the swap has to invalidate it explicitly, exactly as
        // CollectionView does for `CardSearchIndex`.
        .onChange(of: collection?.catalogGeneration) { catalog.clear() }
        .task(id: wants.entries.count) { rebuildShareLink(r) }
        .sheet(item: $editing) { card in
            WishlistEditSheet(card: card, price: r.rawUsd[card.id], wants: wants)
        }
    }

    @ViewBuilder private func content(_ r: Resolved, _ cards: [CardRecord]) -> some View {
        header(r)
        if groupBySet {
            let grouped = groupedBySet(cards, setsById: r.setsById)
            ForEach(grouped, id: \.setId) { section in
                Section {
                    grid(section.cards, rawUsd: r.rawUsd)
                } header: { sectionHeader(section.name) }
            }
        } else if sort == .priority && priorityFilter == nil {
            // Default view: dividers between High / Normal / Low. `cards` is already
            // priority-sorted, so filtering per group preserves the in-group price order.
            ForEach(WantPriority.allCases) { p in
                let group = cards.filter { priority($0.id) == p }
                if !group.isEmpty {
                    Section {
                        grid(group, rawUsd: r.rawUsd)
                    } header: { sectionHeader("\(p.label) priority") }
                }
            }
        } else {
            grid(cards, rawUsd: r.rawUsd)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.top, 8)
    }

    private func header(_ r: Resolved) -> some View {
        let total = totalUsd(r)
        let atTarget = atTargetCount(r)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(r.allCards.count) cards")
                Text("·").foregroundStyle(.secondary)
                Text(total, format: .currency(code: "USD")).monospacedDigit()
                if atTarget > 0 {
                    Text("· \(atTarget) at target")
                        .foregroundStyle(.green).font(.caption).bold()
                }
            }
            .font(.subheadline)
            if let asOf = try? store.priceAsOf() { AsOfLabel(date: asOf) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.top, 8)
    }

    private func grid(_ cards: [CardRecord], rawUsd: [String: Double]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(cards) { card in
                NavigationLink(value: CardID(raw: card.id)) {
                    WishlistTile(card: card, priceUsd: rawUsd[card.id], entry: wants.entry(card.id),
                                 inCollectedSet: goals?.isCollecting(card.setId) ?? false)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { editing = card } label: {
                        Label("Edit wishlist details", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) { wants.toggle(card.id) } label: {
                        Label("Remove from Wishlist", systemImage: "heart.slash")
                    }
                }
            }
        }.padding()
    }

    private func groupedBySet(_ cards: [CardRecord], setsById: [String: SetRecord]) -> [(setId: String, name: String, cards: [CardRecord])] {
        var order: [String] = []
        var byId: [String: [CardRecord]] = [:]
        for c in cards {
            if byId[c.setId] == nil { order.append(c.setId) }
            byId[c.setId, default: []].append(c)
        }
        return order.map { ($0, setsById[$0]?.name ?? $0, byId[$0] ?? []) }
    }

    @ToolbarContentBuilder private func sortMenu(disabled: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(WishlistSort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Priority", selection: $priorityFilter) {
                    Text("All priorities").tag(WantPriority?.none)
                    ForEach(WantPriority.allCases) { Text($0.label).tag(WantPriority?.some($0)) }
                }
                Toggle("Group by set", isOn: $groupBySet)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .disabled(disabled)
        }
    }

    /// Export (CSV data) and Print (PDF sheet) under one icon. The section titles say what each
    /// produces, so the difference is visible before tapping.
    ///
    /// ⚠️ **Not a `ShareLink`, and not inside the menu** — see `ShareSheet`. This one shipped
    /// broken in v1.0: from build 23 (when iPad shipped) until 2026-08-01, "Link to this list" was
    /// unusable on an iPad, while working fine on every iPhone.
    @ToolbarContentBuilder private func shareMenu(r: Resolved, disabled: Bool) -> some ToolbarContent {
        ToolbarItem {
            // A link a friend can open without the app — the thing you actually paste into
            // Discord before a meetup. Carries card ids only; see `ShareList`.
            Button {
                if let shareLink { sharing = SharePayload(url: shareLink.url) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel((shareLink?.included ?? 0) < r.allCards.count
                                ? "Share a link to the first \(shareLink?.included ?? 0) cards"
                                : "Share a link to this list")
            .disabled(disabled || shareLink == nil)
        }
        ToolbarItem {
            Menu {
                Section("Export as CSV (spreadsheet)") {
                    Button("All cards") { exportCSV(r, priority: nil) }
                    ForEach(WantPriority.allCases) { p in
                        Button("\(p.label) priority only") { exportCSV(r, priority: p) }
                    }
                }
                Section("Print (PDF of card images)") {
                    Button("All cards") { printSheet(r, priority: nil) }
                    ForEach(WantPriority.allCases) { p in
                        Button("\(p.label) priority only") { printSheet(r, priority: p) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More")
            .disabled(disabled)
        }
    }

    /// The whole wishlist, or just one priority tier. Ignores the on-screen search — "Low priority
    /// only" means the low list, full stop — so Export/Print subsets match their menu labels.
    private func subset(_ r: Resolved, priority p: WantPriority?) -> [CardRecord] {
        p == nil ? r.allCards : r.allCards.filter { priority($0.id) == p }
    }

    /// Most valuable first, so a list too long for a URL keeps the cards worth talking about.
    /// Target price and priority ride along — they're what turn a list of names into an ask.
    private func rebuildShareLink(_ r: Resolved) {
        let ordered = WishlistGrid.sorted(cards: r.allCards, entries: wants.entries,
                                          prices: r.rawUsd,
                                          setDates: r.setsById.mapValues { $0.releaseDate ?? "" },
                                          by: .expensive)
        let items = ordered.map { card -> ShareList.Item in
            let entry = wants.entry(card.id)
            // Normal priority is the default on the other side too, so it's not worth the bytes.
            let priority = entry?.priority
            return ShareList.Item(c: card.id, n: card.name, s: r.setsById[card.setId]?.name,
                                  t: entry?.targetUsd,
                                  p: priority == nil || priority == .normal
                                     ? nil : priority?.label.lowercased())
        }
        shareLink = try? ShareList.link(kind: .want, items: items)
    }

    private func exportCSV(_ r: Resolved, priority p: WantPriority?) {
        exportName = p.map { "the-tin-wishlist-\($0.label.lowercased())" } ?? "the-tin-wishlist"
        exportDoc = CSVDocument(data: CollectionCSV.exportWishlist(
            cards: subset(r, priority: p), sets: r.setsById, prices: r.priceRecords, entries: wants.entries))
    }

    private func printSheet(_ r: Resolved, priority p: WantPriority?) {
        printRequest = PrintSheet.wantRequest(cards: subset(r, priority: p), store: store)
    }
}

/// The wishlist's catalog reads, held across body passes.
///
/// A reference type held in `@State`, for the same reason `CardSearchIndex` is one: filling it
/// while `body` evaluates isn't a state mutation, so it needs no `.task` round trip and there's
/// no empty first frame to flash through. Two different lifetimes are cached separately — the
/// set table changes only when the catalog artifact does, while cards and prices change whenever
/// the wishlist does. Filtering, sorting and grouping deliberately stay live: they're arithmetic
/// over an array that's already in memory, and caching them would only add ways to go stale.
fileprivate final class WishlistCatalog {
    private var sets: [String: SetRecord]?
    private var wantedKey: Set<String>?
    private var resolved = WantedCardsView.Resolved()

    func resolve(wanted: Set<String>, store: CatalogStore) -> WantedCardsView.Resolved {
        if sets == nil {
            sets = Dictionary(uniqueKeysWithValues: ((try? store.sets()) ?? []).map { ($0.id, $0) })
        }
        guard wantedKey != wanted else { return resolved }
        let allCards = (try? store.cards(ids: Array(wanted))) ?? []
        let priceRecords = (try? store.prices(cardIds: allCards.map(\.id))) ?? [:]
        // compactMapValues: a null raw_usd (EUR/graded only) is treated as unpriced, not $0.
        resolved = WantedCardsView.Resolved(allCards: allCards, priceRecords: priceRecords,
                                            rawUsd: priceRecords.compactMapValues(\.rawUsd),
                                            setsById: sets ?? [:])
        wantedKey = wanted
        return resolved
    }

    func clear() {
        sets = nil
        wantedKey = nil
        resolved = WantedCardsView.Resolved()
    }
}

/// One wishlist card tile: art + name + price, with priority/notes/on-sale signals.
private struct WishlistTile: View {
    let card: CardRecord
    let priceUsd: Double?
    let entry: WantEntry?
    /// This card's set is one you're collecting, so it's already tracked in the gap. It stays on
    /// the wishlist (you chose it, and it may carry a target price) but says why it's in both.
    var inCollectedSet: Bool = false

    private var onSale: Bool { WishlistGrid.isOnSale(card, entry: entry, price: priceUsd) }

    var body: some View {
        VStack(spacing: 4) {
            CardImageView(card: card, quality: "low")
                .overlay(alignment: .topLeading) { priorityDot }
                .overlay(alignment: .topTrailing) { noteGlyph }
            Text(card.name).font(.caption).lineLimit(1)
            // Shown only when it applies. The grid top-aligns its cells, so a tile without this
            // caption is simply shorter — it no longer has to carry a blank line to keep its
            // neighbours in step.
            if inCollectedSet {
                Text("In a set you collect")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            priceLabel
        }
    }

    @ViewBuilder private var priorityDot: some View {
        if let p = entry?.priority, p != .normal {
            Image(systemName: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(p == .high ? .red : .gray)
                .padding(4)
                .accessibilityLabel(p == .high ? "High priority" : "Low priority")
        }
    }

    @ViewBuilder private var noteGlyph: some View {
        if let n = entry?.notes, !n.isEmpty {
            Image(systemName: "note.text")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(4).accessibilityLabel("Has notes")
        }
    }

    @ViewBuilder private var priceLabel: some View {
        if let usd = priceUsd {
            HStack(spacing: 2) {
                if onSale { Image(systemName: "target").font(.system(size: 9)) }
                Text(usd, format: .currency(code: "USD"))
            }
            .font(.caption2).monospacedDigit()
            .foregroundStyle(onSale ? Color.green : Color.primary)
        }
    }
}
