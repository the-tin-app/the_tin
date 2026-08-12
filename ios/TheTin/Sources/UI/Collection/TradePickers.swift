import SwiftUI

/// Pick one of your own copies to put on the table.
///
/// Opens on the For Trade list, because that flag finally means something here — but every owned
/// copy is reachable below it. Trades happen to cards you hadn't decided to trade yet.
struct TradeOwnedPicker: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    /// Copies of each entry already on your side of the table, so a row can show what it has
    /// contributed. The picker stays open across several taps — without this it is a list of
    /// buttons that produce no visible result, and the only way to check a tap landed is to close
    /// the sheet and look.
    var onTable: [String: Int] = [:]
    let add: (CollectionEntry) -> Void

    @State private var search = ""
    /// Bumped on every tap purely to drive the haptic. The counts come from the session and can
    /// hold steady across a tap (a stack already at its owned quantity won't grow), so keying the
    /// feedback on them would silently swallow exactly the taps that need explaining.
    @State private var taps = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !forTrade.isEmpty {
                Section("On your trade list") { rows(forTrade) }
            }
            Section(forTrade.isEmpty ? "Your cards" : "Everything else") { rows(others) }
        }
        .searchable(text: $search, prompt: "Your cards")
        .navigationTitle("Your side")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: taps)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .overlay {
            if forTrade.isEmpty && others.isEmpty {
                ContentUnavailableView("No cards match", systemImage: "magnifyingglass")
            }
        }
    }

    private var matching: [CollectionEntry] {
        guard !search.isEmpty else { return model.entries }
        let needle = search.lowercased()
        return model.entries.filter {
            (try? store.card(id: $0.cardId))?.name.lowercased().contains(needle) ?? false
        }
    }

    private var forTrade: [CollectionEntry] { matching.filter(\.isForTrade) }
    private var others: [CollectionEntry] { matching.filter { !$0.isForTrade } }

    @ViewBuilder private func rows(_ entries: [CollectionEntry]) -> some View {
        ForEach(entries) { entry in
            Button {
                taps += 1
                add(entry)
            } label: {
                HStack(spacing: 8) {
                    CollectionEntryRow(card: try? store.card(id: entry.cardId),
                                       entry: entry,
                                       dividerName: dividerName(entry),
                                       value: model.entryValue(entry))
                    OnTableBadge(copies: onTable[entry.id], limit: entry.qty)
                }
            }
        }
    }

    private func dividerName(_ entry: CollectionEntry) -> String {
        entry.groupId.isEmpty ? "No divider"
            : (model.groups.first { $0.id == entry.groupId }?.name ?? "No divider")
    }
}

/// "×2 on the table" — the receipt for a tap, on the row that was tapped.
///
/// Also the place a refused tap becomes visible: your side can never hold more copies than you
/// own, so tapping a single at ×1 again is a no-op, and without something on screen saying it is
/// already at its limit that reads as the button being broken.
private struct OnTableBadge: View {
    let copies: Int?
    /// Copies available. nil where there is no ceiling (their side is not drawn from a shelf).
    var limit: Int? = nil

    var body: some View {
        if let copies {
            let maxed = limit.map { copies >= $0 } ?? false
            Text(maxed ? "×\(copies) · all" : "×\(copies)")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.statusPositive.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.statusPositive)
                .accessibilityLabel(maxed ? "\(copies) on the table, all you own"
                                          : "\(copies) on the table")
        }
    }
}

/// Pick a card from the catalog for their side. They're cards you don't own, so there is nothing
/// local to pick from — this is the same offline FTS5 search the Search tab uses, plus the camera,
/// because the cards on their side of the table are in a stranger's hands and you cannot type a
/// name you can't read from across it.
struct TradeCatalogPicker: View {
    let store: CatalogStore
    var wants: WantsModel? = nil
    /// Defaults to the trade wording it was written for. The virtual binder reuses this picker for
    /// "none of these — search instead", where "Their side" would be nonsense.
    var title: String = "Their side"
    /// The three the scanner needs. All optional together: the binder's reuse of this picker has
    /// none of them, and a camera button that opens a viewfinder with no pack behind it is worse
    /// than no camera button.
    var collection: CollectionModel? = nil
    var pack: ScannerPackModel? = nil
    var staging: ScanStagingStore? = nil
    /// Copies of each card id already on their side — the same receipt `TradeOwnedPicker` shows.
    var onTable: [String: Int] = [:]
    let add: (CardRecord) -> Void

    @State private var model: SearchModel?
    @State private var taps = 0
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss

    /// Every piece present AND a usable pack. `.ready` rather than `isScannerUsable`: this opens
    /// a viewfinder immediately, so a pack that is mid-download has nothing to offer yet.
    private var canScan: Bool {
        collection != nil && staging != nil && pack?.phase == .ready
    }

    var body: some View {
        Group {
            if let model {
                list(model)
            } else {
                TinLoadingView(label: "Preparing search…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: taps)
        .toolbar {
            if canScan {
                ToolbarItem(placement: .topBarLeading) {
                    Button { scanning = true } label: {
                        Label("Scan a card", systemImage: "camera.viewfinder")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .fullScreenCover(isPresented: $scanning) {
            if let collection, let pack, let staging {
                TradeScanSheet(store: store, collection: collection, pack: pack,
                               staging: staging, wants: wants) { card in
                    taps += 1
                    add(card)
                }
            }
        }
        .task { if model == nil { model = SearchModel(store: store) } }
    }

    @ViewBuilder private func list(_ model: SearchModel) -> some View {
        @Bindable var model = model
        List(model.results) { card in
            Button {
                taps += 1
                add(card)
            } label: {
                HStack(spacing: 12) {
                    CardImageView(card: card, quality: "low").frame(width: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(card.name).lineLimit(1)
                            // The whole reason to receive someone's list in the app: which of it
                            // you're actually hunting, without reading every name.
                            if wants?.isWanted(card.id) == true {
                                Image(systemName: "heart.fill")
                                    .font(.caption2).foregroundStyle(.pink) // contrast-ok: glyph, not text
                                    .accessibilityLabel("On your wanted list")
                            }
                        }
                        Text(model.caption(for: card))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    OnTableBadge(copies: onTable[card.id])
                    if let usd = model.prices[card.id]?.rawUsd {
                        Text(usd, format: WidgetShared.tinCurrency(usd))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $model.text, prompt: "Card name")
        .overlay {
            // An empty List and no explanation used to be the FIRST thing this picker showed:
            // the overlay required non-empty text, so opening it landed on a blank white sheet
            // with a search bar. The Search tab has always said what to do here.
            if model.results.isEmpty {
                if model.text.isEmpty {
                    ContentUnavailableView("Find their card", systemImage: "magnifyingglass",
                                           description: Text(canScan
                                               ? "Search the catalog by name, or scan the card with the camera button."
                                               : "Search the catalog by name."))
                } else {
                    ContentUnavailableView.search(text: model.text)
                }
            }
        }
    }
}

/// The live scanner, pointed at someone else's card.
///
/// Look-up mode all the way down: their card is not entering your tin, so nothing may be staged.
/// `ScanView.onLookUp` is what makes that a two-line reuse rather than a second viewfinder — the
/// ring, the guidance, the ambiguous chooser and the camera plumbing all have one home.
private struct TradeScanSheet: View {
    let store: CatalogStore
    let collection: CollectionModel
    let pack: ScannerPackModel
    let staging: ScanStagingStore
    var wants: WantsModel? = nil
    let onScanned: (CardRecord) -> Void

    /// Its OWN capture session, and a separate one from the Scan tab's. Only one
    /// `AVCaptureSession` may run at a time, which holds here because the Scan tab's `ScanView`
    /// leaves the hierarchy when this tab is on screen — `AVCaptureFrameSource.stream()` stops
    /// the session on termination, so the tab's is already down before this one starts.
    @State private var source = AVCaptureFrameSource()
    /// Built in a task, never in `body` — the same rule (and the same reason) as
    /// `ScanTabContainer.model`: a fresh `ScanModel` per re-render orphans the running pipeline.
    @State private var model: ScanModel?
    /// The last card put on the table, held so the sheet can confirm the capture without closing.
    /// You are scanning a pile, not one card.
    @State private var lastScanned: CardRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ScanView(model: model, staging: staging, collection: collection,
                             store: store, source: source, wants: wants, onLookUp: put)
                } else {
                    TinLoadingView(label: "Starting camera…")
                        .task {
                            guard model == nil, let matcher = pack.matcher,
                                  let index = pack.index else { return }
                            model = ScanModel(matcher: matcher, detector: CardDetector(),
                                              textGate: TextGate(index: index), narrowing: index,
                                              staging: staging, store: store)
                        }
                }
            }
            .navigationTitle("Scan their card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let lastScanned {
                    // The scanner's own "Added X — next card" line belongs to staging, which this
                    // mode does not do. Without a confirmation of its own, a scan that landed on
                    // the table looks exactly like a scan that didn't.
                    Label("Added \(lastScanned.name) to their side",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.statusPositive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.thinMaterial)
                }
            }
        }
    }

    private func put(_ cardId: String) {
        guard let card = try? store.card(id: cardId) else { return }
        lastScanned = card
        onScanned(card)
    }
}
