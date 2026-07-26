import SwiftUI

/// Camera preview + coverage ring + guidance + ambiguous chooser + a live staging tray
/// (count, running value, haptic) with a Review entry point. Drives `ScanModel.run`.
struct ScanView: View {
    @Bindable var model: ScanModel
    let staging: ScanStagingStore
    let collection: CollectionModel
    let store: CatalogStore
    let source: AVCaptureFrameSource
    var wants: WantsModel? = nil
    @State private var showingReview = false

    /// What the tin already knows about the card that just landed in the tray — the "do I need
    /// this?" answer, read at the moment your hands are still on the card.
    private var latestKnowledge: ScanKnowledge? {
        guard let id = staging.drafts.first?.cardId else { return nil }
        return ScanKnowledge.of(cardId: id, entries: collection.entries,
                                wanted: wants?.wanted ?? [])
    }

    var body: some View {
        ZStack {
            CameraPreview(session: source.session).ignoresSafeArea()
            // Visual guide only — the pipeline analyzes the matching central window defined by
            // ScanGuide.cropRect (single source of truth for "what the scanner looks at").
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.85), lineWidth: 3)
                .aspectRatio(0.717, contentMode: .fit)
                .padding(28)
            VStack {
                HStack {
                    Spacer()
                    // Escape hatch: clears the scanner to a clean slate (votes, lock, chooser, and
                    // any rejected-card suppression). Does NOT drop staged cards. Available in every
                    // state, including while a chooser is frozen.
                    Button { Task { await model.reset() } } label: {
                        Label("Reset", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Clears the current scan and looks again")
                }
                Spacer()
                VStack(spacing: 8) {
                    CoverageRing(value: model.coverage)
                    // Amber while a chooser is frozen ("Scanning paused"), material otherwise.
                    Text(model.guidance).font(.headline).padding(8)
                        .background(model.ambiguous.isEmpty ? AnyShapeStyle(.ultraThinMaterial)
                                                            : AnyShapeStyle(Color.orange.opacity(0.9)),
                                    in: Capsule())
                    if model.ambiguous.isEmpty {
                        modePicker
                        // Only in Add mode: look-up stages nothing, so a condition for the thing
                        // it isn't recording would be one more control saying nothing.
                        if !model.isLookUpMode { conditionPicker }
                        // In look-up mode the tray is noise until something is actually staged —
                        // but staged cards from an earlier session still need their way back.
                        if !model.isLookUpMode || !staging.drafts.isEmpty {
                            StagingTray(staging: staging, store: store,
                                        condition: model.isLookUpMode ? nil : model.stagingCondition,
                                        knowledge: latestKnowledge) { showingReview = true }
                        }
                    } else {
                        // Variant A (approved 2026-07-15): bottom sheet, 2×2 card-image grid.
                        AmbiguousChooser(model: model, options: model.ambiguous)
                    }
                }
                // Anchored on the controls stack, NOT the root: the root already carries the
                // review sheet, and two `.sheet` modifiers on one view is the case SwiftUI
                // silently drops (same class as StagingReviewView's "tap twice, no prompt").
                .sheet(item: lookedUpBinding) { lookUpSheet($0) }
            }.padding()
        }
        // A capture you needed feels different from a capture you didn't: the celebratory
        // `.success` is now spent on a wishlist hit, and a routine card gets a light tick. Only
        // fires on a capture — the old form buzzed on removals too, because any count change
        // tripped it.
        .sensoryFeedback(trigger: staging.drafts.count) { old, new in
            guard new > old else { return nil }
            return latestKnowledge?.wanted == true ? .success : .impact(weight: .light)
        }
        .sheet(isPresented: $showingReview) {
            NavigationStack {
                StagingReviewView(staging: staging, collection: collection, store: store, wants: wants)
            }
        }
        .task { await model.run(source: source) }
    }

    /// Add vs. look up. Two different questions get asked of a card in hand — "file this" while
    /// cataloguing a box, and "what is this?" standing in a shop — and the scanner only ever
    /// answered the first, so asking the second cost a stage-then-delete round trip.
    private var modePicker: some View {
        Picker("Scanner mode", selection: $model.isLookUpMode) {
            Text("Add to tin").tag(false)
            Text("Look up").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHint(model.isLookUpMode
                           ? "Scanned cards are shown, not saved"
                           : "Scanned cards are staged for review")
    }

    /// The condition every capture is staged at, until you change it. A per-card question in the
    /// rapid loop is exactly what spec D5 emptied out of it — but the answer was silently "Near
    /// Mint" for everything, so a bulk lot of played commons valued itself as mint. One control,
    /// set once per stack, sticky across launches like the mode picker beside it.
    private var conditionPicker: some View {
        Picker("Condition", selection: $model.stagingCondition) {
            ForEach(CardCondition.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Condition for scanned cards")
        .accessibilityHint("New scans are staged at this condition")
    }

    /// Bridges the model's looked-up card id to `.sheet(item:)`. Dismissing clears it AND resets
    /// the scanner, so the next frame reads fresh.
    private var lookedUpBinding: Binding<CardID?> {
        Binding(get: { model.lookedUpCardId.map { CardID(raw: $0) } },
                set: { if $0 == nil { Task { await model.clearLookedUpCard() } } })
    }

    @ViewBuilder private func lookUpSheet(_ id: CardID) -> some View {
        if let card = try? store.card(id: id.raw) {
            NavigationStack {
                CardDetailView(model: CardDetailModel(store: store, card: card,
                                                      history: CatalogPriceHistory(store: store)),
                               store: store, collection: collection, wants: wants)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { Task { await model.clearLookedUpCard() } }
                        }
                    }
            }
        }
    }
}

private struct CoverageRing: View {
    let value: Double
    var body: some View {
        Circle().trim(from: 0, to: value).stroke(.green, lineWidth: 6)
            .frame(width: 44, height: 44).rotationEffect(.degrees(-90))
            .accessibilityLabel("Scan coverage")
            .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// Variant A chooser (approved 2026-07-15): a dark bottom sheet with a 2×2 grid of card
/// images + name + "Set · Year · #num/total", and a "None of these" escape that resumes
/// scanning. Options are frozen by ScanSession while this is visible.
private struct AmbiguousChooser: View {
    let model: ScanModel
    let options: [ChooserOption]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(options) { option in
                    Button { Task { await model.chooseAmbiguous(cardId: option.id) } } label: {
                        VStack(spacing: 6) {
                            CardImageView(card: option.card, quality: "low")
                                .frame(maxWidth: 96)
                            VStack(spacing: 1) {
                                Text(option.card?.name ?? option.id)
                                    .font(.caption.bold()).foregroundStyle(.white)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text(option.caption)
                                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                Task { await model.dismissChooser() }
            } label: {
                Text("None of these — keep scanning")
                    .font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.28)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Bottom tray: live count + running value + a Review button. The count-triggered
/// `.sensoryFeedback` in `ScanView` is the "✓ captured" haptic in the rapid scan loop.
private struct StagingTray: View {
    let staging: ScanStagingStore
    let store: CatalogStore
    /// The condition captures are being staged at; nil in look-up mode, where nothing is staged.
    /// Shown because the running total is computed at it — an assumption behind a number on
    /// screen should be visible next to that number.
    let condition: CardCondition?
    /// What the tin already knows about the newest capture; nil when the tray is empty.
    let knowledge: ScanKnowledge?
    let onReview: () -> Void
    private var latestCard: CardRecord? {
        guard let id = staging.drafts.first?.cardId else { return nil }
        return try? store.card(id: id)
    }
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail of the most-recent capture = instant "got the right card?" glance,
            // badged with the answer to "do I need it?".
            if staging.drafts.first != nil {
                CardImageView(card: latestCard, quality: "low").frame(width: 34)
                    .overlay(alignment: .topTrailing) {
                        if let k = knowledge, k.isNotable {
                            CardBadges(owned: k.ownedCount > 0, wanted: k.wanted)
                                .scaleEffect(0.85)
                        }
                    }
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "tray.full").imageScale(.large)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(staging.drafts.count) card](inflect: true) staged").font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text(staging.totalUsd, format: .currency(code: "USD"))
                    if let condition {
                        Text("at \(condition.rawValue)").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                // Only when there's something to say — a card you neither own nor want stays quiet
                // so the line means something when it does appear.
                if let caption = knowledge?.caption {
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(knowledge?.wanted == true ? Color.pink : Color.green)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trayAccessibilityLabel)
            Spacer()
            Button("Review") { onReview() }
                .buttonStyle(.borderedProminent)
                .disabled(staging.drafts.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var trayAccessibilityLabel: String {
        var base = "\(staging.drafts.count) \(staging.drafts.count == 1 ? "card" : "cards") staged, \(staging.totalUsd.formatted(.currency(code: "USD")))"
        if let condition { base += ", at \(condition.rawValue)" }
        guard let caption = knowledge?.caption else { return base }
        return base + ". Latest: " + caption
    }
}
