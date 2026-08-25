import SwiftUI

/// One divider, laid out as a binder: pages of pockets, each showing what is planned for it and
/// whether you have it.
///
/// Presented as a `.sheet`, deliberately. A `navigationDestination` closure re-runs on every
/// parent body evaluation, which is what emptied card detail for two days (PR #119); a sheet
/// sidesteps the question and costs no route in `NavValues`.
struct BinderLayoutView: View {
    @Bindable var model: CollectionModel
    let group: CardGroup
    let store: CatalogStore
    let binders: BinderLayoutsModel
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    /// Catalog records for everything planned in this binder, loaded off the main actor.
    @State private var cards: [String: CardRecord] = [:]
    @State private var pendingShrink: PendingShrink?
    /// The pocket a tap wants to fill, held until `BinderPlaceSheet` commits or is dismissed.
    @State private var pendingPlace: PendingPlace?

    /// A shape change that would discard planned cards, held until the user confirms it.
    private struct PendingShrink: Identifiable {
        let id = UUID()
        let shape: PageShape?
        let losing: Int
    }

    /// One pocket, identified by its page and index within that page.
    private struct PendingPlace: Identifiable {
        let page: Int
        let index: Int
        var id: String { "\(page)-\(index)" }
    }

    /// The sheets people actually buy. A page can also inherit the binder's own default, which is
    /// the fifth option in the menu and not in this list.
    private static let offeredShapes = [
        PageShape(rows: 1, cols: 1), PageShape(rows: 2, cols: 2),
        PageShape(rows: 3, cols: 3), PageShape(rows: 3, cols: 4),
    ]

    static func pageLabel(index: Int, of layout: BinderLayout) -> String {
        "Page \(index + 1) of \(max(layout.pages.count, 1))"
    }

    private static func shapeLabel(_ shape: PageShape) -> String { "\(shape.rows)×\(shape.cols)" }

    /// nil until this divider is laid out — and a layout with ZERO pages is the same thing.
    ///
    /// `place`/`insert` are no-ops on a page that does not exist, so a zero-page layout must never
    /// be drawn as a spread of pockets: every tap would be a dead end. It renders as
    /// not-laid-out-yet instead, which is also where Task 11 hangs the setup controls. The
    /// invariant the rest of the feature leans on: **a layout, once created, always has at least
    /// one page.**
    private var layout: BinderLayout? {
        guard let stored = binders.layout(for: group.id), !stored.pages.isEmpty else { return nil }
        return stored
    }

    var body: some View {
        NavigationStack {
            Group {
                if let layout {
                    spread(layout)
                } else {
                    ContentUnavailableView(
                        "Not laid out yet", systemImage: "book.closed",
                        description: Text("\(group.name) is a divider, not a binder — there are no pages to show."))
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            // Off the main actor, keyed on the layout: twelve pockets is twelve card lookups, and
            // `CardDetailModel` is the precedent for what doing those synchronously costs.
            .task(id: layout) { await loadCards() }
            // `page` is derived from the layout's contents, so it goes stale the moment the layout
            // shrinks — a shape change, a restore, a page removed. Clamp on every change; nothing
            // below indexes `pages` without a bounds check either.
            .onChange(of: layout) { clampPage() }
            // A `Picker` is what people flick through to PREVIEW options, and `save` writes to
            // disk immediately — so a lossy shrink asks first. A lossless one never does: resizing
            // an empty page stays one tap.
            .confirmationDialog("Smaller page", isPresented: Binding(
                get: { pendingShrink != nil },
                set: { if !$0 { pendingShrink = nil } }
            ), presenting: pendingShrink) { pending in
                Button("Remove \(pending.losing) \(pending.losing == 1 ? "card" : "cards")",
                       role: .destructive) { applyShape(pending.shape) }
                Button("Keep this page", role: .cancel) {}
            } message: { pending in
                Text("This page holds \(pending.losing) more \(pending.losing == 1 ? "card" : "cards") than the new size. They'll be removed from the binder — the cards stay in your collection.")
            }
            // Attached to this stable `Group`, never to the `switch`/`if` inside `spread` — a
            // `.sheet` on a re-identified branch dismisses itself (the same `ViewBuilder`
            // conditional-identity trap this codebase has hit before).
            .sheet(item: $pendingPlace) { pending in
                if let layout {
                    BinderPlaceSheet(layout: layout, page: pending.page, index: pending.index,
                                     store: store) { updated in binders.save(updated) }
                }
            }
        }
    }

    @ViewBuilder private func spread(_ layout: BinderLayout) -> some View {
        VStack(spacing: 12) {
            pageBar(layout)
            ScrollView { pocketGrid(layout) }
        }
        .padding()
    }

    @ViewBuilder private func pageBar(_ layout: BinderLayout) -> some View {
        HStack {
            Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(page <= 0)
                .accessibilityLabel("Previous page")
            Spacer()
            VStack(spacing: 2) {
                Text(Self.pageLabel(index: page, of: layout))
                    .font(.caption).foregroundStyle(.secondary)
                shapeMenu(layout)
            }
            Spacer()
            Button { page += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(page >= layout.pages.count - 1)
                .accessibilityLabel("Next page")
        }
    }

    /// Sets or clears THIS page's shape override. Saving normalizes, which resizes the page's slot
    /// array to its new shape — so shrinking a page drops the planned cards that no longer fit.
    @ViewBuilder private func shapeMenu(_ layout: BinderLayout) -> some View {
        let own = layout.pages.indices.contains(page) ? layout.pages[page].shape : nil
        Menu {
            // A lone inline Picker: it renders its options without its own label (see
            // GroupDetailView's toolbar), which is fine here — the menu's label below IS the label.
            Picker("Page size", selection: shapeBinding(layout)) {
                Text("Binder default (\(Self.shapeLabel(layout.shape)))").tag(PageShape?.none)
                ForEach(Self.offeredShapes, id: \.self) { shape in
                    Text(Self.shapeLabel(shape)).tag(PageShape?.some(shape))
                }
            }
        } label: {
            Text("\(Self.shapeLabel(own ?? layout.shape)) pockets")
                .font(.caption)
        }
        .accessibilityLabel("Page size")
        .accessibilityValue(Self.shapeLabel(own ?? layout.shape))
    }

    private func shapeBinding(_ layout: BinderLayout) -> Binding<PageShape?> {
        Binding(
            get: { layout.pages.indices.contains(page) ? layout.pages[page].shape : nil },
            set: { chosen in
                let losing = loss(changingTo: chosen)
                if losing > 0 {
                    pendingShrink = PendingShrink(shape: chosen, losing: losing)
                } else {
                    applyShape(chosen)
                }
            })
    }

    /// How many planned cards changing `page` to `shape` would discard.
    ///
    /// `normalized()` truncates the slot array to the new shape and `save` writes immediately, so
    /// without this the picker silently destroys hand-placed work — eleven cards on a 3×4
    /// master-set page going to 1×1. The cards themselves stay in the collection; it is the PLAN
    /// that is lost. Static and pure so the branch that decides destroy-vs-confirm is assertable.
    static func loss(in page: BinderPage, changingTo shape: PageShape?,
                     default fallback: PageShape) -> Int {
        page.slots.dropFirst((shape ?? fallback).pockets).compactMap { $0 }.count
    }

    private func loss(changingTo shape: PageShape?) -> Int {
        guard let layout, layout.pages.indices.contains(page) else { return 0 }
        return Self.loss(in: layout.pages[page], changingTo: shape, default: layout.shape)
    }

    private func applyShape(_ shape: PageShape?) {
        guard var updated = layout, updated.pages.indices.contains(page) else { return }
        updated.pages[page].shape = shape
        binders.save(updated)
    }

    @ViewBuilder private func pocketGrid(_ layout: BinderLayout) -> some View {
        let shape = layout.pages.indices.contains(page)
            ? layout.pages[page].effectiveShape(default: layout.shape)
            : layout.shape
        let states = BinderFill.states(layout: layout, entries: model.entries)
        // LAZY, and `alignment: .top` so a two-line caption doesn't make its row ragged. A page of
        // twelve is twelve `CardImageView`s; a non-lazy row of card tiles has already cost this app
        // a jetsam, which is a SIGKILL and so invisible to Crashlytics.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                 count: shape.cols), spacing: 8) {
            ForEach(0..<shape.pockets, id: \.self) { i in
                Button {
                    pendingPlace = PendingPlace(page: page, index: i)
                } label: {
                    pocket(layout: layout, index: i,
                           state: states.indices.contains(page) && states[page].indices.contains(i)
                                  ? states[page][i] : .empty)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func pocket(layout: BinderLayout, index: Int, state: SlotState) -> some View {
        let planned = layout.pages.indices.contains(page)
            && layout.pages[page].slots.indices.contains(index)
            ? layout.pages[page].slots[index] : nil
        VStack(spacing: 4) {
            if let planned {
                // Told apart at a glance: art means you have it, ghosted-and-dashed means you
                // don't. A card the catalog can't resolve still renders as a planned pocket
                // (`CardImageView` takes an optional record) rather than reading as empty.
                CardImageView(card: cards[planned.cardId], quality: "low")
                    .opacity(state == .filled ? 1 : 0.3)
                    .overlay {
                        if state != .filled {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                                .foregroundStyle(.secondary)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.quaternary)
                    .aspectRatio(0.72, contentMode: .fit)
            }
            // Only when the id names a divider that still exists. An ungrouped entry carries
            // `groupId == ""`, which names none — and "in " with nothing after it is worse than
            // no caption at all.
            if case .needed(let elsewhere) = state, let elsewhere,
               let name = model.groups.first(where: { $0.id == elsewhere })?.name {
                Text("in \(name)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    /// One batched catalog read, off the main actor.
    private func loadCards() async {
        let ids = Array(Set((layout?.pages ?? []).flatMap { $0.slots }.compactMap { $0?.cardId }))
        guard !ids.isEmpty else { cards = [:]; return }
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? store.cards(ids: ids)) ?? []
        }.value
        // NOT `uniqueKeysWithValues`, which traps. `id` is a primary key so a duplicate can't
        // happen today, and a trap on catalog data is not worth the tighter init.
        cards = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Pure so it can be asserted. `page` is `@State` derived from the layout's contents, and this
    /// codebase has twice been bitten by such state outliving what it was derived from.
    static func clamped(_ page: Int, pages: Int) -> Int { min(max(page, 0), max(pages - 1, 0)) }

    private func clampPage() {
        page = Self.clamped(page, pages: layout?.pages.count ?? 0)
    }
}
