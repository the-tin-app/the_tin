import SwiftUI
import UniformTypeIdentifiers

/// Grid of the user's wanted cards, resolved from the offline catalog by id. Reached only via
/// `WantedRoute`. Sort/search/group + per-card priority/target/notes signals.
struct WantedCardsView: View {
    let store: CatalogStore
    let wants: WantsModel
    var collection: CollectionModel? = nil

    @State private var sort: WishlistSort = .priority
    @State private var search = ""
    @State private var groupBySet = false
    @State private var editing: CardRecord?
    @State private var printRequest: PrintSheetRequest?
    @State private var exportDoc: CSVDocument?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    private var allCards: [CardRecord] { (try? store.cards(ids: Array(wants.wanted))) ?? [] }
    private var priceRecords: [String: PriceRecord] {
        (try? store.prices(cardIds: allCards.map(\.id))) ?? [:]
    }
    // compactMapValues: a null raw_usd (EUR/graded only) is treated as unpriced, not $0.
    private var rawUsd: [String: Double] { priceRecords.compactMapValues(\.rawUsd) }
    private var setsById: [String: SetRecord] {
        Dictionary(uniqueKeysWithValues: ((try? store.sets()) ?? []).map { ($0.id, $0) })
    }

    /// Search filter, then chosen sort.
    private var cards: [CardRecord] {
        let base = search.isEmpty ? allCards
            : allCards.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return WishlistGrid.sorted(cards: base, entries: wants.entries, prices: rawUsd,
                                   setDates: setsById.mapValues { $0.releaseDate ?? "" }, by: sort)
    }

    private var totalUsd: Double { allCards.compactMap { rawUsd[$0.id] }.reduce(0, +) }
    private var atTargetCount: Int {
        allCards.filter { WishlistGrid.isOnSale($0, entry: wants.entry($0.id), price: rawUsd[$0.id]) }.count
    }

    var body: some View {
        Group {
            if allCards.isEmpty {
                ContentUnavailableView {
                    Label { Text("Your wishlist is empty") }
                    icon: { Image(systemName: "heart").foregroundStyle(.pink) }
                } description: {
                    Text("Tap the heart on any card to start hunting for it here.")
                }
            } else {
                ScrollView { content }
            }
        }
        .navigationTitle("Wishlist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search wishlist")
        .toolbar { sortMenu; exportButton; printButton }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil },
                                           set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .commaSeparatedText,
                      defaultFilename: CollectionCSV.filename("the-tin-wishlist")) { _ in
            exportDoc = nil
        }
        .printSheetFlow($printRequest)
        .sheet(item: $editing) { card in
            WishlistEditSheet(card: card, price: rawUsd[card.id], wants: wants)
        }
    }

    @ViewBuilder private var content: some View {
        header
        if groupBySet {
            let grouped = groupedBySet(cards)
            ForEach(grouped, id: \.setId) { section in
                Section {
                    grid(section.cards)
                } header: {
                    Text(section.name).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.top, 8)
                }
            }
        } else {
            grid(cards)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(allCards.count) cards")
                Text("·").foregroundStyle(.secondary)
                Text(totalUsd, format: .currency(code: "USD")).monospacedDigit()
                if atTargetCount > 0 {
                    Text("· \(atTargetCount) at target")
                        .foregroundStyle(.green).font(.caption).bold()
                }
            }
            .font(.subheadline)
            if let asOf = try? store.priceAsOf() { AsOfLabel(date: asOf) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.top, 8)
    }

    private func grid(_ cards: [CardRecord]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(cards) { card in
                NavigationLink(value: CardID(raw: card.id)) {
                    WishlistTile(card: card, priceUsd: rawUsd[card.id], entry: wants.entry(card.id))
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

    private func groupedBySet(_ cards: [CardRecord]) -> [(setId: String, name: String, cards: [CardRecord])] {
        var order: [String] = []
        var byId: [String: [CardRecord]] = [:]
        for c in cards {
            if byId[c.setId] == nil { order.append(c.setId) }
            byId[c.setId, default: []].append(c)
        }
        return order.map { ($0, setsById[$0]?.name ?? $0, byId[$0] ?? []) }
    }

    @ToolbarContentBuilder private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(WishlistSort.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Group by set", isOn: $groupBySet)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .disabled(allCards.isEmpty)
        }
    }

    @ToolbarContentBuilder private var exportButton: some ToolbarContent {
        ToolbarItem {
            Button {
                exportDoc = CSVDocument(data: CollectionCSV.exportWishlist(
                    cards: cards, sets: setsById, prices: priceRecords, entries: wants.entries))
            } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("Export wishlist (CSV)")
            .disabled(allCards.isEmpty)
        }
    }

    @ToolbarContentBuilder private var printButton: some ToolbarContent {
        ToolbarItem {
            Button { printRequest = PrintSheet.wantRequest(cards: cards, store: store) } label: {
                Label("Print want list…", systemImage: "printer")
            }
            .disabled(allCards.isEmpty)
        }
    }
}

/// One wishlist card tile: art + name + price, with priority/notes/on-sale signals.
private struct WishlistTile: View {
    let card: CardRecord
    let priceUsd: Double?
    let entry: WantEntry?

    private var onSale: Bool { WishlistGrid.isOnSale(card, entry: entry, price: priceUsd) }

    var body: some View {
        VStack(spacing: 4) {
            CardImageView(card: card, quality: "low")
                .overlay(alignment: .topLeading) { priorityDot }
                .overlay(alignment: .topTrailing) { noteGlyph }
            Text(card.name).font(.caption).lineLimit(1)
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
