import SwiftUI

/// Turn a divider into a binder: pick the page size, optionally lay a whole set out in it.
///
/// ⚠️ NOT `BinderSetupView` — that name belongs to the Lens scanner in this same module, along
/// with eighteen other `Binder*` types.
///
/// The only way a layout is ever created, so it owns the invariant the rest of the feature leans
/// on: **a layout always has at least one page**. `place`/`insert` are no-ops on a page that does
/// not exist, so a pageless binder would be a screen of dead taps.
struct BinderSetupSheet: View {
    let groupId: String
    let store: CatalogStore
    let onCreate: (BinderLayout) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shape = PageShape.default
    @State private var sets: [SetRecord] = []
    @State private var chosen: SetRecord?
    @State private var reverseHolos = false
    /// A master set is ~400 cards over two catalog queries, so the button becomes a spinner
    /// rather than sitting there looking tappable.
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Page size") {
                    Picker("Pockets per page", selection: $shape) {
                        ForEach(BinderLayoutView.offeredShapes, id: \.self) { shape in
                            Text(BinderLayoutView.shapeLabel(shape)).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    NavigationLink {
                        BinderSetupSetList(sets: sets, chosen: $chosen)
                    } label: {
                        LabeledContent("Fill from a set", value: chosen?.name ?? "None")
                    }
                    Toggle("Include reverse holos", isOn: $reverseHolos)
                        .disabled(chosen == nil)
                } footer: {
                    Text("A set is laid out in collector order, one pocket per card. Leave it as None to start with a single empty page.")
                }
            }
            .navigationTitle("Lay out as a binder")
            .navigationBarTitleDisplayMode(.inline)
            .task { sets = await Self.loadSets(store: store) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create") { create() }
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func create() {
        working = true
        Task {
            let pages = await Self.build(setId: chosen?.id, shape: shape,
                                         reverseHolos: reverseHolos, store: store)
            onCreate(BinderLayout(groupId: groupId, shape: shape, pages: pages))
            dismiss()
        }
    }

    /// The pages a new binder starts with. **Never zero** — `BinderLayout.pages` returns `[]` for
    /// an empty card list, which is what a set the catalog holds no cards for would produce.
    /// `save` normalizes, so an unsized page becomes a full page of empty pockets on disk.
    static func initialPages(cards: [CardRecord], shape: PageShape,
                             reverseHoloFor eligible: Set<String>) -> [BinderPage] {
        let pages = BinderLayout.pages(for: cards, shape: shape, reverseHoloFor: eligible)
        return pages.isEmpty ? [BinderPage()] : pages
    }

    /// Two catalog queries over hundreds of rows, off the main actor — same shape as
    /// `BinderPlaceSheet.search` and `BinderLayoutView.loadCards`.
    static func build(setId: String?, shape: PageShape, reverseHolos: Bool,
                      store: CatalogStore) async -> [BinderPage] {
        guard let setId else { return initialPages(cards: [], shape: shape, reverseHoloFor: []) }
        return await Task.detached(priority: .userInitiated) {
            let cards = (try? store.cards(inSet: setId)) ?? []
            // Only cards the catalog actually prices a reverse-holo printing for: one per card
            // would double a 400-card set with pockets that can never be filled.
            let priced = reverseHolos
                ? (try? store.variantPrices(cardIds: cards.map(\.id))) ?? [:]
                : [:]
            return initialPages(cards: cards, shape: shape,
                                reverseHoloFor: BinderLayout.reverseHoloEligible(in: priced))
        }.value
    }

    private static func loadSets(store: CatalogStore) async -> [SetRecord] {
        await Task.detached(priority: .userInitiated) { (try? store.sets()) ?? [] }.value
    }
}

/// The catalog holds several hundred sets, so this is searchable. A plain `Picker` would push an
/// unsearchable list of all of them.
private struct BinderSetupSetList: View {
    let sets: [SetRecord]
    @Binding var chosen: SetRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            Button("None — start empty") { chosen = nil; dismiss() }
            ForEach(filtered) { set in
                Button {
                    chosen = set
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(set.name).lineLimit(1)
                        Text(caption(set)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // ⚠️ `.buttonStyle(.plain)` hit-tests the RENDERED CONTENT, not the frame, so
                    // `maxWidth: .infinity` widened the layout and left the tap target the width
                    // of the words. Measured on the simulator: live to x≈120 of a 402pt row, dead
                    // from 140 out — about 70% of the row, including its centre, where a finger
                    // actually lands. The sibling "None — start empty" row has no plain style and
                    // was the only selectable thing in the list.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $search, prompt: "Set name")
        // Only for a search that found nothing. An empty list with an empty query is the sets
        // still loading, and "No results for ''" is a worse thing to show than a blank moment.
        .overlay { if filtered.isEmpty, !search.isEmpty { ContentUnavailableView.search(text: search) } }
        .navigationTitle("Fill from a set")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "1999 · 102 cards" — the year is what tells two similarly named sets apart.
    private func caption(_ set: SetRecord) -> String {
        let date = set.releaseDate ?? ""
        let year = date.count >= 4 ? String(date.prefix(4)) : ""
        let cards = "\(set.total) cards"
        return year.isEmpty ? cards : "\(year) · \(cards)"
    }

    /// Plain string filtering over a few hundred rows — no catalog query, so it stays inline.
    private var filtered: [SetRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sets }
        return sets.filter { $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }
    }
}
