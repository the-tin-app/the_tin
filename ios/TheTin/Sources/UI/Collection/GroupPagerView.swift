import SwiftUI
import Charts

/// Flip through one stack of the tin — one full-width page per owned card (art, saved
/// printing/condition/grade, value, paid→now delta, price trend). A pure deck: the divider's
/// summary/stats live on its list-first landing (`GroupDetailView`, 2026-07-17 UX pass).
/// Lazy paging (`LazyHStack` + `.paging`) so a 300-card tin doesn't load 300 images up front.
struct GroupPagerView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    let groupId: String?   // nil = the whole tin ("Everything")
    @State private var editingEntry: CollectionEntry?
    @State private var pageId: String?

    private var group: CardGroup? { groupId.flatMap { id in model.groups.first { $0.id == id } } }
    private var title: String { group?.name ?? "Everything" }
    private var color: Color { group.map { DividerPalette.color(for: $0.id) } ?? DividerPalette.steel }
    private var entries: [CollectionEntry] {
        groupId.map { model.entries(in: $0).sorted { $0.addedAt > $1.addedAt } } ?? model.allOwnedEntries
    }
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(entries) { entry in
                    EntryCardPage(model: model, store: store, entry: entry, accent: color,
                                  onEdit: { editingEntry = $0 })
                        .containerRelativeFrame(.horizontal)
                        .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageId)
        .scrollIndicators(.hidden)
        // The bottom "3 of 12" capsule is visual-only; tell VoiceOver where the swipe landed.
        .onChange(of: pageId) { _, new in
            guard let new, let i = entries.firstIndex(where: { $0.id == new }) else { return }
            AccessibilityNotification.Announcement("Card \(i + 1) of \(entries.count)").post()
        }
        // Deleting the visible card leaves pageId on a removed id (capsule vanishes, scroll
        // landing undefined) — land on the card that slid into its slot, else the last one.
        .onChange(of: entries.map(\.id)) { old, new in
            guard let current = pageId, !new.contains(current) else { return }
            let i = old.firstIndex(of: current) ?? 0
            pageId = i < new.count ? new[i] : new.last
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { positionLabel }
        .overlay {
            if entries.isEmpty {
                Text("Nothing behind this divider yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
    }

    @ViewBuilder private var positionLabel: some View {
        if let pageId, let i = entries.firstIndex(where: { $0.id == pageId }) {
            Text("\(i + 1) of \(entries.count)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 6)
        }
    }
}

/// One card, held up out of the tin: big art, the sleeve label (printing · condition · grade),
/// what it's worth today, what you paid, and its price trend.
private struct EntryCardPage: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    let entry: CollectionEntry
    let accent: Color
    let onEdit: (CollectionEntry) -> Void
    @State private var history: [PricePoint] = []
    @State private var confirmingRemove = false

    private var card: CardRecord? { try? store.card(id: entry.cardId) }
    private var value: Double? { model.entryValue(entry) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CardImageView(card: card, quality: "high")
                    .frame(maxHeight: 380)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 5)

                HStack(alignment: .firstTextBaseline) {
                    Text(card?.name ?? entry.cardId).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    menu
                }

                chips

                VStack(spacing: 3) {
                    if let value {
                        Text(value, format: .currency(code: "USD"))
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                    } else {
                        Text("No price data").font(.title3).foregroundStyle(.secondary)
                    }
                    if let paid = entry.pricePaid {
                        paidDelta(paid: paid)
                    }
                    if value != nil, let asOf = model.priceAsOf {
                        AsOfLabel(date: asOf)
                    }
                }

                if history.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        // Accent blue, not the divider pastel: the raw-market series keeps one
                        // color everywhere (it's blue in PriceHistoryChart too).
                        Sparkline(points: history, color: .accentColor)
                            .frame(height: 56)
                        if let first = history.first?.date, let last = history.last?.date {
                            // Date-range caption instead of axis marks — keeps the sparkline bare
                            // but answers "what time span is this?".
                            (Text("raw market trend · ") + Text(first...last))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding()
        }
        .task(id: entry.cardId) { history = (try? store.priceHistory(cardId: entry.cardId)) ?? [] }
        .confirmationDialog(
            "Remove \(card?.name ?? "this card") from your tin?",
            isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await model.deleteEntry(id: entry.id) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let v = entry.variantValue { chip(v.label) }
            if let c = entry.condition { chip(c) }
            if let g = entry.gradeValue { chip(g.label) }
            if entry.qty > 1 { chip("×\(entry.qty)") }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(accent.opacity(0.3), in: Capsule())
    }

    private func paidDelta(paid: Double) -> some View {
        HStack(spacing: 6) {
            Text("paid \(paid, format: .currency(code: "USD"))")
                .foregroundStyle(.secondary)
            if let value {
                let delta = value - paid
                HStack(spacing: 2) {
                    Image(systemName: delta >= 0 ? "arrow.up" : "arrow.down").font(.caption2.bold())
                    Text(abs(delta), format: .currency(code: "USD"))
                }
                .foregroundStyle(delta >= 0 ? .green : .red)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(delta >= 0 ? "up" : "down") \(abs(delta).formatted(.currency(code: "USD"))) since you bought it")
            }
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
    }

    private var menu: some View {
        Menu {
            Button { onEdit(entry) } label: { Label("Edit entry", systemImage: "pencil") }
            Menu {
                if entry.groupId != "" {
                    Button("No divider") { Task { await model.moveEntry(entry, toGroup: "") } }
                }
                ForEach(model.groups.filter { $0.id != entry.groupId }) { g in
                    Button(g.name) { Task { await model.moveEntry(entry, toGroup: g.id) } }
                }
            } label: { Label("Move to…", systemImage: "arrow.turn.up.right") }
            NavigationLink(value: CardID(raw: entry.cardId)) {
                Label("Card details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) { confirmingRemove = true }
                label: { Label("Remove from tin", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Entry actions")
    }
}
