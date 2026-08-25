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
    }

    private func shapeBinding(_ layout: BinderLayout) -> Binding<PageShape?> {
        Binding(
            get: { layout.pages.indices.contains(page) ? layout.pages[page].shape : nil },
            set: { chosen in
                guard layout.pages.indices.contains(page) else { return }
                var updated = layout
                updated.pages[page].shape = chosen
                binders.save(updated)
            })
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
                pocket(layout: layout, index: i,
                       state: states.indices.contains(page) && states[page].indices.contains(i)
                              ? states[page][i] : .empty)
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

    private func clampPage() {
        page = min(max(page, 0), max((layout?.pages.count ?? 0) - 1, 0))
    }
}
