import SwiftUI
import TipKit

/// Reviews staged drafts before they become owned: per-card price, variant, condition,
/// remove, and routing to a group / new group / the Tin. Editing here defers all per-scan
/// taps out of the rapid capture loop (spec D5).
struct StagingReviewView: View {
    @Bindable var staging: ScanStagingStore
    let collection: CollectionModel
    let store: CatalogStore
    /// Drives the "do I need this?" line on each row. Optional so previews/tests can omit it.
    var wants: WantsModel? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hidesPrices) private var hidesPrices
    @State private var routing: ScanDraft?     // draft being routed
    @State private var measuring: ScanDraft?   // draft whose centring is being placed
    /// Where this tray's scan plates live. Injectable so tests and previews can point elsewhere.
    var platesDir: URL = ScanStagingPaths.default().platesDir
    @State private var newGroupName = ""
    /// Who the "New divider" alert is naming a divider for — one draft, or the whole tray.
    @State private var showingNewGroup: FilingTarget?
    @State private var showingClearConfirm = false
    @State private var routingAll = false
    /// Drafts the last filing couldn't write; 0 = no error showing.
    @State private var failedToFile = 0
    // Batch-fetched once on open (same tables the collection UI uses); drive draft repricing.
    @State private var prices: [String: PriceRecord] = [:]
    @State private var variantsByCard: [String: [VariantPrice]] = [:]
    @State private var conditionsByCard: [String: [ConditionPrice]] = [:]
    @State private var matrixByCard: [String: [MatrixPrice]] = [:]
    @State private var gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]
    // Gate: only a load where all three fetches actually succeeded may drive a reprice —
    // an empty-but-successful dict still counts as loaded (see loadPricesAndReprice doc).
    @State private var pricesLoaded = false

    var body: some View {
        List {
            // Answers the centring line rather than pointing at a control, so it sits above the
            // rows that carry it. Suppressed on an empty tray — there is no line to explain yet.
            if !staging.drafts.isEmpty { TipView(CenteringReviewTip()) }
            Section {
                ForEach(staging.drafts) { draft in
                    DraftRow(draft: draft, store: store,
                             knowledge: ScanKnowledge.of(cardId: draft.cardId,
                                                         entries: collection.entries,
                                                         wanted: wants?.wanted ?? []),
                             variantPrices: variantsByCard[draft.cardId] ?? [],
                             onVariant: { staging.updateVariant(id: draft.id, $0); repriceAll() },
                             onCondition: { staging.updateCondition(id: draft.id, $0); repriceAll() },
                             onRemove: { staging.remove(id: draft.id) },
                             onRoute: { routing = draft },
                             onMeasure: { measuring = draft })
                }
            } header: {
                if !staging.drafts.isEmpty {
                    HStack {
                        Text("^[\(staging.drafts.count) card](inflect: true)")
                        Spacer()
                        // Sums the same per-draft snapshots as the scan tray's running total.
                        if !hidesPrices { Text(staging.totalUsd, format: .currency(code: "USD")) }
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
            // #199: a stack of scans usually goes behind ONE divider, and filing them one row at a
            // time was the whole complaint. Only with 2+ drafts — for one, the row's own "File
            // in…" is the same thing. Dialog anchored on the button for the reason "Clear all"
            // gives below.
            ToolbarItem(placement: .bottomBar) {
                if staging.drafts.count > 1 {
                    Button("File all ^[\(staging.drafts.count) card](inflect: true) in…") { routingAll = true }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog("File all ^[\(staging.drafts.count) card](inflect: true) in…",
                                            isPresented: $routingAll, titleVisibility: .visible) {
                            routeAllDialogActions
                        }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Confirm before wiping the whole tray. Anchored on the button, NOT the root view:
                // a second .confirmationDialog stacked on the root (already carries the routing one
                // + two alerts) is the case SwiftUI silently drops — the "tap twice, no prompt" bug.
                Button("Clear all", role: .destructive) { showingClearConfirm = true }
                    .disabled(staging.drafts.isEmpty)
                    .confirmationDialog("Clear all staged cards?", isPresented: $showingClearConfirm,
                                        titleVisibility: .visible) {
                        Button("Clear ^[\(staging.drafts.count) card](inflect: true)",
                               role: .destructive) { staging.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("This removes every scan from the review list. It can't be undone.") }
            }
        }
        .confirmationDialog("File this card in…", isPresented: routingIsPresented, titleVisibility: .visible) {
            routeDialogActions
        }
        .alert("New divider", isPresented: newGroupIsPresented) {
            newGroupAlertActions
        }
        .sheet(item: $measuring) { draft in
            NavigationStack {
                if let name = draft.plateFile,
                   let image = UIImage(contentsOfFile: platesDir.appendingPathComponent(name).path) {
                    CenteringEditorView(plate: image, initial: draft.centering) { measured in
                        staging.updateCentering(id: draft.id, measured)
                    }
                } else {
                    // The plate went missing under us — a purge, or a write that failed after the
                    // draft was saved. Say so; an empty editor would read as a broken screen.
                    ContentUnavailableView("Scan image missing", systemImage: "photo",
                                           description: Text("Re-scan this card to measure it."))
                }
            }
        }
        .alert(failedToFile > 1 ? "Couldn't file \(failedToFile) cards" : "Couldn't file that card",
               isPresented: commitErrorIsPresented) {
            commitErrorAlertActions
        } message: {
            Text(failedToFile > 1 ? "They're still in your staging tray — try again."
                                  : "It's still in your staging tray — try again.")
        }
    }

    /// Bridges the optional `routing` draft to the `Bool` the confirmation dialog needs.
    private var routingIsPresented: Binding<Bool> {
        Binding(get: { routing != nil }, set: { if !$0 { routing = nil } })
    }

    private var commitErrorIsPresented: Binding<Bool> {
        Binding(get: { failedToFile > 0 }, set: { if !$0 { failedToFile = 0 } })
    }

    /// Bridges the optional `showingNewGroup` target to the `Bool` the alert needs.
    private var newGroupIsPresented: Binding<Bool> {
        Binding(get: { showingNewGroup != nil }, set: { if !$0 { showingNewGroup = nil } })
    }

    @ViewBuilder
    private var routeDialogActions: some View {
        if let draft = routing {
            Button("No divider") { Task { await commit(draft, to: .tin) } }
            ForEach(collection.groups) { g in
                Button(g.name) { Task { await commit(draft, to: .group(g.id)) } }
            }
            Button("New divider…") { showingNewGroup = .one(draft); routing = nil }
            Button("Cancel", role: .cancel) { routing = nil }
        }
    }

    @ViewBuilder
    private var routeAllDialogActions: some View {
        Button("No divider") { Task { await commitAll(to: .tin) } }
        ForEach(collection.groups) { g in
            Button(g.name) { Task { await commitAll(to: .group(g.id)) } }
        }
        Button("New divider…") { showingNewGroup = .all }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var newGroupAlertActions: some View {
        TextField("Name", text: $newGroupName)
        Button("Create") {
            let target = showingNewGroup; let name = newGroupName.trimmingCharacters(in: .whitespaces)
            showingNewGroup = nil; newGroupName = ""
            guard let target, !name.isEmpty else { return }
            switch target {
            case .one(let draft): Task { await commit(draft, to: .newGroup(name)) }
            case .all: Task { await commitAll(to: .newGroup(name)) }
            }
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
            failedToFile = 1               // keep the draft; let the user retry
        }
    }

    /// Same rule as `commit`, for the whole tray: only drafts with a confirmed write leave it.
    private func commitAll(to destination: RouteDestination) async {
        let drafts = staging.drafts
        let filed = await collection.commitScans(drafts, to: destination)
        for id in filed { staging.remove(id: id) }
        failedToFile = drafts.count - filed.count
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
        // Old-artifact fallback per store convention (matrix/graded reads throw pre-migration).
        matrixByCard = (try? store.matrixPrices(cardIds: ids)) ?? [:]
        gradedByPrintingByCard = (try? store.gradedPrintingPrices(cardIds: ids)) ?? [:]
        // The scan-time variant is a blind defaultFor(rarity:) guess and can name a finish the
        // card isn't actually printed in (Tomas, 2026-07-21: Tyranitar δ defaulted to Regular but
        // only comes in Holo/Reverse Holo). Now that the real printings are loaded, snap any such
        // draft to the first finish it IS offered in, so the row shows a real finish + real price.
        for d in staging.drafts {
            let offered = EntryFormView.offeredVariants(catalog: v[d.cardId] ?? [])
            if !offered.contains(d.variant), let first = offered.first {
                staging.updateVariant(id: d.id, first)
            }
        }
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
                                 conditions: conditionsByCard[d.cardId] ?? [],
                                 matrix: matrixByCard[d.cardId] ?? [],
                                 gradedByPrinting: gradedByPrintingByCard[d.cardId] ?? [])
        }
    }
}

/// What the review screen is filing: one row's draft, or every draft in the tray.
private enum FilingTarget: Equatable {
    case one(ScanDraft)
    case all
}

private struct DraftRow: View {
    let draft: ScanDraft
    let store: CatalogStore
    @Environment(\.hidesPrices) private var hidesPrices
    /// Copies already in the tin + wishlist state for this card — "do I need this?" answered
    /// on the row, so a stack of scans can be triaged without opening each card.
    let knowledge: ScanKnowledge
    let variantPrices: [VariantPrice]   // card's real PPT printings — filters the finish picker
    let onVariant: (CardVariant) -> Void
    let onCondition: (CardCondition) -> Void
    let onRemove: () -> Void
    let onRoute: () -> Void
    let onMeasure: () -> Void

    private var card: CardRecord? { try? store.card(id: draft.cardId) }
    private var title: String { card?.name ?? draft.cardId }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Card art = at-a-glance confirmation the scan found the right card.
            CardImageView(card: card, quality: "low").frame(width: 58)
                .overlay(alignment: .topTrailing) {
                    if knowledge.isNotable {
                        CardBadges(owned: knowledge.ownedCount > 0, wanted: knowledge.wanted)
                            .scaleEffect(0.85)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if hidesPrices {
                        EmptyView()
                    } else if let p = draft.priceUsdSnapshot {
                        Text(p, format: .currency(code: "USD")).foregroundStyle(.secondary)
                    } else { Text("—").foregroundStyle(.secondary) }
                }
                if let caption = knowledge.caption {
                    Text(caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(knowledge.wanted
                                         ? Color.statusWishlist : Color.statusPositive)
                }
                // Only ever shows a number a person has placed — see `Centering`. Without a plate
                // there is nothing to drag lines on, so the row says nothing rather than offering
                // a control that opens an empty screen.
                if draft.plateFile != nil {
                    Button(action: onMeasure) {
                        Label(draft.centering.map { "Centering \($0.summary)" } ?? "Measure centering",
                              systemImage: "square.dashed")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.centering == nil ? Color.accentColor : .secondary)
                    .accessibilityLabel(draft.centering?.spokenSummary ?? "Measure centering")
                    .accessibilityHint("Opens the scan so you can place the border lines")
                }
                // Plain tinted menus (no borders/icons) so labels never hyphenate on
                // narrow rows; approved mockup option A, CTA wording "File in…".
                HStack(spacing: 16) {
                    Menu {
                        ForEach(EntryFormView.validVariants(catalog: variantPrices, current: draft.variant)) {
                            v in Button(v.label) { onVariant(v) }
                        }
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
