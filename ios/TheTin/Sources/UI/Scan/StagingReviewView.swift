import SwiftUI

/// Reviews staged drafts before they become owned: per-card price, variant, condition,
/// remove, and routing to a group / new group / the Tin. Editing here defers all per-scan
/// taps out of the rapid capture loop (spec D5).
struct StagingReviewView: View {
    @Bindable var staging: ScanStagingStore
    let collection: CollectionModel
    let store: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var routing: ScanDraft?     // draft being routed
    @State private var newGroupName = ""
    @State private var showingNewGroup: ScanDraft?
    @State private var commitError = false
    // Batch-fetched once on open (same tables the collection UI uses); drive draft repricing.
    @State private var prices: [String: PriceRecord] = [:]
    @State private var variantsByCard: [String: [VariantPrice]] = [:]
    @State private var conditionsByCard: [String: [ConditionPrice]] = [:]
    // Gate: only a load where all three fetches actually succeeded may drive a reprice —
    // an empty-but-successful dict still counts as loaded (see loadPricesAndReprice doc).
    @State private var pricesLoaded = false

    var body: some View {
        List {
            Section {
                ForEach(staging.drafts) { draft in
                    DraftRow(draft: draft, store: store,
                             onVariant: { staging.updateVariant(id: draft.id, $0); repriceAll() },
                             onCondition: { staging.updateCondition(id: draft.id, $0); repriceAll() },
                             onRemove: { staging.remove(id: draft.id) },
                             onRoute: { routing = draft })
                }
            } header: {
                if !staging.drafts.isEmpty {
                    HStack {
                        Text("^[\(staging.drafts.count) card](inflect: true)")
                        Spacer()
                        // Sums the same per-draft snapshots as the scan tray's running total.
                        Text(staging.totalUsd, format: .currency(code: "USD"))
                    }
                }
            }
        }
        .task { loadPricesAndReprice() }
        .overlay {
            if staging.drafts.isEmpty {
                ContentUnavailableView("Nothing staged", systemImage: "tray",
                                       description: Text("Scanned cards will appear here to review."))
            }
        }
        .navigationTitle("Review scans")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear all", role: .destructive) { staging.clear() }
                    .disabled(staging.drafts.isEmpty)
            }
        }
        .confirmationDialog("File this card in…", isPresented: routingIsPresented, titleVisibility: .visible) {
            routeDialogActions
        }
        .alert("New group", isPresented: newGroupIsPresented) {
            newGroupAlertActions
        }
        .alert("Couldn't file that card", isPresented: $commitError) {
            commitErrorAlertActions
        } message: { Text("It's still in your staging tray — try again.") }
    }

    /// Bridges the optional `routing` draft to the `Bool` the confirmation dialog needs.
    private var routingIsPresented: Binding<Bool> {
        Binding(get: { routing != nil }, set: { if !$0 { routing = nil } })
    }

    /// Bridges the optional `showingNewGroup` draft to the `Bool` the alert needs.
    private var newGroupIsPresented: Binding<Bool> {
        Binding(get: { showingNewGroup != nil }, set: { if !$0 { showingNewGroup = nil } })
    }

    @ViewBuilder
    private var routeDialogActions: some View {
        if let draft = routing {
            Button("The Tin (no group)") { Task { await commit(draft, to: .tin) } }
            ForEach(collection.groups) { g in
                Button(g.name) { Task { await commit(draft, to: .group(g.id)) } }
            }
            Button("New group…") { showingNewGroup = draft; routing = nil }
            Button("Cancel", role: .cancel) { routing = nil }
        }
    }

    @ViewBuilder
    private var newGroupAlertActions: some View {
        TextField("Name", text: $newGroupName)
        Button("Create") {
            let draft = showingNewGroup; let name = newGroupName.trimmingCharacters(in: .whitespaces)
            showingNewGroup = nil; newGroupName = ""
            guard let draft, !name.isEmpty else { return }
            Task { await commit(draft, to: .newGroup(name)) }
        }
        Button("Cancel", role: .cancel) { showingNewGroup = nil; newGroupName = "" }
    }

    @ViewBuilder
    private var commitErrorAlertActions: some View {
        Button("OK", role: .cancel) {}
    }

    private func commit(_ draft: ScanDraft, to destination: RouteDestination) async {
        if await collection.commitScan(draft, to: destination) {
            staging.remove(id: draft.id)   // only leave staging on a confirmed write
        } else {
            commitError = true             // keep the draft; let the user retry
        }
    }

    /// Batch-fetch the price tables for every staged card, then reprice all drafts with the
    /// shared resolution (GroupStats.unitPrice). A query THROWING is not the same as a query
    /// returning no rows: only commit + reprice when all three fetches succeed (an empty-but-
    /// successful dict still counts). On any throw — on open, or later from an edit callback
    /// via repriceAll's own gate — we keep the blind scan-time snapshots instead of nil-ing
    /// them out; repriceAll refuses to run at all until one successful load has landed.
    private func loadPricesAndReprice() {
        let ids = Array(Set(staging.drafts.map(\.cardId)))
        guard !ids.isEmpty,
              let p = try? store.prices(cardIds: ids),
              let v = try? store.variantPrices(cardIds: ids),
              let c = try? store.conditionPrices(cardIds: ids) else { return }
        prices = p
        variantsByCard = v
        conditionsByCard = c
        pricesLoaded = true
        repriceAll()
    }

    /// Drafts have no grade; unpriced selections fall back raw/NM inside unitPrice —
    /// the same silent fallback the collection UI uses (spec: no caveat text). No-op until
    /// loadPricesAndReprice has completed a fully-successful load (see its doc) — guards the
    /// per-edit onVariant/onCondition callers too, so a failed open can't get nil-ed by an edit.
    private func repriceAll() {
        guard pricesLoaded else { return }
        staging.reprice { d in
            GroupStats.unitPrice(condition: d.condition, variant: d.variant,
                                 price: prices[d.cardId],
                                 variants: variantsByCard[d.cardId] ?? [],
                                 conditions: conditionsByCard[d.cardId] ?? [])
        }
    }
}

private struct DraftRow: View {
    let draft: ScanDraft
    let store: CatalogStore
    let onVariant: (CardVariant) -> Void
    let onCondition: (CardCondition) -> Void
    let onRemove: () -> Void
    let onRoute: () -> Void

    private var card: CardRecord? { try? store.card(id: draft.cardId) }
    private var title: String { card?.name ?? draft.cardId }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Card art = at-a-glance confirmation the scan found the right card.
            CardImageView(card: card, quality: "low").frame(width: 58)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let p = draft.priceUsdSnapshot {
                        Text(p, format: .currency(code: "USD")).foregroundStyle(.secondary)
                    } else { Text("—").foregroundStyle(.secondary) }
                }
                // Plain tinted menus (no borders/icons) so labels never hyphenate on
                // narrow rows; approved mockup option A, CTA wording "File in…".
                HStack(spacing: 16) {
                    Menu {
                        ForEach(CardVariant.allCases) { v in Button(v.label) { onVariant(v) } }
                    } label: { menuLabel(draft.variant.label) }
                    Menu {
                        ForEach(CardCondition.allCases) { c in Button(c.rawValue) { onCondition(c) } }
                    } label: { menuLabel(draft.condition.rawValue) }
                    Spacer()
                    Button("File in…", action: onRoute).buttonStyle(.borderedProminent)
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .swipeActions { Button("Remove", role: .destructive, action: onRemove) }
    }

    /// Menu label as tinted text + a small picker chevron (affordance without a border).
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
        }
        .font(.subheadline)
    }
}
