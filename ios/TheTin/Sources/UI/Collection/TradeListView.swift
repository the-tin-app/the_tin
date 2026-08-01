import SwiftUI

/// Route to the trade list (marker type, like `WantedRoute`).
struct TradeRoute: Hashable {}

/// The cards you've said you'll part with, most valuable first.
///
/// Spares are the currency of this hobby and the app had no notion of them: a fourth copy was
/// just "×4" in the tin total, and the only trade affordance in the whole app was a print action
/// buried in a divider's long-press menu. This is the list you actually bring to a meetup — and
/// what the shareable trade link is built from.
struct TradeListView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    @State private var editingEntry: CollectionEntry?
    @State private var printRequest: PrintSheetRequest?
    /// Built once per change of the list rather than per body pass — encoding is a gzip per
    /// binary-search step, which is cheap but not free.
    @State private var shareLink: (url: URL, included: Int)?
    @State private var sharing: SharePayload?

    var body: some View {
        List {
            if !model.tradeEntries.isEmpty {
                Section {
                    header
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(model.tradeEntries) { entry in
                        NavigationLink(value: CardID(raw: entry.cardId)) {
                            CollectionEntryRow(card: try? store.card(id: entry.cardId),
                                               entry: entry,
                                               dividerName: dividerName(entry),
                                               value: model.entryValue(entry))
                        }
                        .swipeActions(edge: .trailing) {
                            // Not a delete: taking a card off the trade list must never look like
                            // it might remove it from the tin.
                            Button {
                                Task { await model.setForTrade(entry, false) }
                            } label: {
                                Label("Keep", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .leading) {
                            Button { editingEntry = entry } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                    }
                } footer: {
                    let v = model.tradeValue
                    if v.pricedCards < v.totalCards {
                        Text("\(v.pricedCards) of \(v.totalCards) cards priced.")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if model.tradeEntries.isEmpty { emptyState } }
        .navigationTitle("For Trade")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            shareMenu
            ToolbarItem(placement: .primaryAction) {
                // The list you'd already be looking at across a table, so the trade starts from
                // here rather than from a menu somewhere else in the app.
                NavigationLink(value: TradeSessionRoute()) {
                    Label("Start a trade", systemImage: "arrow.left.arrow.right.circle")
                }
                .accessibilityLabel("Start a trade")
            }
        }
        .printSheetFlow($printRequest)
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .task(id: model.tradeEntries.count) { rebuildShareLink() }
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

    private var header: some View {
        let v = model.tradeValue
        return VStack(alignment: .leading, spacing: 2) {
            Text(v.total, format: WidgetShared.tinCurrency(v.total))
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text("\(v.totalCards) \(v.totalCards == 1 ? "card" : "cards") you'll trade")
                .font(.footnote).foregroundStyle(.secondary)
            // See WantedCardsView: the share button is an icon, so the truncation notice that was
            // the menu item's text has to live beside the count instead.
            if let shareLink, shareLink.included < model.tradeEntries.count {
                Text("A shared link fits the \(shareLink.included) most valuable of these.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
        }
    }

    /// Marking is explicit by design — which means without this the screen is blank forever, and
    /// a blank screen on first visit reads as broken rather than as empty.
    private var emptyState: some View {
        let duplicates = model.duplicateCardIds.count
        return ContentUnavailableView {
            Label("No cards marked to trade", systemImage: "arrow.left.arrow.right")
        } description: {
            Text(duplicates == 0
                 ? "Turn on “Available to trade” when you edit a card and it collects here."
                 : "Turn on “Available to trade” when you edit a card — or start from the cards you hold more than one of.")
        } actions: {
            if duplicates > 0 {
                Button("Flag \(duplicates) \(duplicates == 1 ? "duplicate" : "duplicates")") {
                    Task { await model.flagDuplicatesForTrade() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Post it to Discord, or print it and bring it. The link carries card ids and nothing that
    /// identifies you — see `ShareList`.
    ///
    /// ⚠️ **Not a `ShareLink`** — see `ShareSheet` for the four things that were tried first. A
    /// `ShareLink` here anchored its popover to the wrong view on iPad and was unusable.
    @ToolbarContentBuilder private var shareMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let shareLink { sharing = SharePayload(url: shareLink.url) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel((shareLink?.included ?? 0) < model.tradeEntries.count
                                ? "Share a link to the first \(shareLink?.included ?? 0) cards"
                                : "Share a link to this list")
            .disabled(shareLink == nil || model.tradeEntries.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Print (PDF of card images)") {
                    Button("All cards") {
                        printRequest = PrintSheet.tradeRequest(title: "For Trade",
                                                               entries: model.tradeEntries,
                                                               model: model, store: store)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
            .disabled(model.tradeEntries.isEmpty)
        }
    }

    /// Most valuable first, so a list too long for a URL keeps the cards worth talking about.
    /// Names ride along because whoever opens the link usually doesn't have the app.
    private func rebuildShareLink() {
        let setNames = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0.name) })
        let items = model.tradeEntries.map { entry -> ShareList.Item in
            let card = try? store.card(id: entry.cardId)
            return ShareList.Item(c: entry.cardId, n: card?.name,
                                  s: card.flatMap { setNames[$0.setId] },
                                  q: entry.qty, d: entry.condition)
        }
        shareLink = try? ShareList.link(kind: .trade, items: items)
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "No divider"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "No divider")
    }
}
