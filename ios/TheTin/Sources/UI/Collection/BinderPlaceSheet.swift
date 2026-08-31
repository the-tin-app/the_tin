import SwiftUI

/// Choose what goes in a pocket — and choose whether it displaces anything.
///
/// Two actions per result, deliberately distinct: "Put here" is `BinderLayout.place`, which
/// overwrites just this pocket; "Insert" is `BinderLayout.insert`, which shifts every planned card
/// after it along by one. The move-cost row belongs to Insert alone — that readout ("112 cards
/// move · pages 6–18") is the reason to open this screen before re-sleeving a real binder.
struct BinderPlaceSheet: View {
    let layout: BinderLayout
    let page: Int
    let index: Int
    let store: CatalogStore
    let onSave: (BinderLayout) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [CardRecord] = []
    /// setId → "Set name · 1999", loaded once off the main actor. Same cache shape as
    /// `SearchModel`'s — without it a search for "Charizard" is sixty identical-looking rows.
    @State private var setCaptions: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let summary = layout.moveSummary(page: page, index: index) {
                    Section {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    } header: {
                        Text("If you Insert")
                    } footer: {
                        Text("Put here fills just this pocket. Insert makes room for it, and everything already planned after it shifts along by one.")
                    }
                }
                if planned != nil {
                    Section {
                        Button("Clear this pocket", role: .destructive) { clear() }
                    } footer: {
                        Text("Empties the pocket. Nothing else moves, and the card stays in your tin.")
                    }
                }
                Section {
                    ForEach(results) { card in
                        row(card)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("Search the catalog", systemImage: "magnifyingglass",
                                               description: Text("Find a card by name to plan it for this pocket."))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Card name")
            .task { setCaptions = await Self.loadCaptions(store: store) }
            .task(id: searchText) { results = await Self.search(searchText, store: store) }
            .navigationTitle("Add a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func row(_ card: CardRecord) -> some View {
        HStack(spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name).lineLimit(1)
                Text(caption(for: card)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(spacing: 6) {
                Button("Put here") { commit(card, shifting: false) }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Insert") { commit(card, shifting: true) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    /// "Base Set · 1999 · #4" — set first: it's what tells two same-named cards apart. Mirrors
    /// `SearchModel.caption(for:)`.
    private func caption(for card: CardRecord) -> String {
        let number = "#\(card.number)"
        guard let set = setCaptions[card.setId] else { return number }
        return "\(set) · \(number)"
    }

    /// What this pocket currently holds — the clear action's whole existence test. `place(nil,…)`
    /// is the only way to undo a mis-tapped Insert, which otherwise shifts a whole master set by
    /// one pocket with no way back.
    private var planned: PlannedCard? {
        guard layout.pages.indices.contains(page),
              layout.pages[page].slots.indices.contains(index) else { return nil }
        return layout.pages[page].slots[index]
    }

    private func clear() {
        var updated = layout
        updated.place(nil, page: page, index: index)
        onSave(updated)
        dismiss()
    }

    private func commit(_ card: CardRecord, shifting: Bool) {
        var updated = layout
        let planned = PlannedCard(cardId: card.id, variant: nil)
        if shifting {
            updated.insert(planned, page: page, index: index)
        } else {
            updated.place(planned, page: page, index: index)
        }
        onSave(updated)
        dismiss()
    }

    /// Off the main actor: `CatalogStore.search` is FTS5 over the whole catalog, and this codebase
    /// has already paid once for a synchronous catalog read stalling a view
    /// (`BinderLayoutView.loadCards()`'s header comment is the precedent for doing this detached).
    private static func search(_ text: String, store: CatalogStore) async -> [CardRecord] {
        let query = SearchQuery.parse(text)
        guard !query.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? store.search(query)) ?? []
        }.value
    }

    private static func loadCaptions(store: CatalogStore) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            var captions: [String: String] = [:]
            for set in (try? store.sets()) ?? [] {
                let date = set.releaseDate ?? ""
                let year = date.count >= 4 ? String(date.prefix(4)) : ""
                captions[set.id] = year.isEmpty ? set.name : "\(set.name) · \(year)"
            }
            return captions
        }.value
    }
}
