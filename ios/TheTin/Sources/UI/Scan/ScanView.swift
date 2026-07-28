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
    /// Collapsed by default — mode and condition are set once per stack, not per card.
    @State private var showingSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            //
            // Sized as a FRACTION of the frame, mirroring cropRect's own maths. It used to be
            // `.padding(28)` — a fixed inset, so the box grew with the screen: ~334pt wide on a
            // phone, but roughly 734×1024pt on a 10" iPad. A card-shaped target the size of the
            // display is not something you can fill, which is both why it read as meaningless
            // ("you can't quite make out what it might be trying to get you to do") and,
            // plausibly, why detection stalled: `ScanGuide.quadPasses` needs the card's long side
            // to be ≥40% of the window's, and an unfillable box keeps the card small in frame.
            // Reported on an iPad 7th gen, 2026-07-27.
            GeometryReader { geo in
                let side = min(geo.size.width * ScanGuide.guideFrameFraction,
                               geo.size.height * ScanGuide.guideFrameFraction * ScanGuide.cardAspect)
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.85), lineWidth: 3)
                    .aspectRatio(ScanGuide.cardAspect, contentMode: .fit)
                    .frame(width: side, height: side / ScanGuide.cardAspect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)   // centred in the preview
            }
            .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    settingsControl
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
                    // Lock-streak progress, not `coverage` — coverage was a flat 1.0 on every heavy
                    // frame that never reset, so this ring snapped full on the first frame and then
                    // meant nothing. It now fills once per confirming frame and empties when the
                    // card leaves, which on a slow device is the difference between "it's working"
                    // and "it's stuck".
                    ConfidenceRing(value: model.lockProgress)
                    // Always says something, and while frames are being examined it says WHAT.
                    //
                    // This used to hide the idle line, on the reasoning that "Frame the card
                    // inside the box" only repeats what the frame rectangle shows. True on a
                    // phone, where recognition is near-instant. On an iPad an A10 grinds through
                    // ORB matching far slower, so the viewfinder went completely silent for
                    // seconds at a time and read as a dead scanner — it was working the whole
                    // while (2026-07-27). Silence is indistinguishable from failure, and the user
                    // pays for the ambiguity by giving up.
                    HStack(spacing: 8) {
                        if model.isExamining && model.ambiguous.isEmpty {
                            // Turns only while frames actually arrive, so it is evidence of work
                            // rather than decoration that spins whether or not anything happens.
                            ProgressView().controlSize(.small)
                        }
                        Text(model.activityText).font(.headline)
                    }
                    .padding(8)
                    // Amber while a chooser is frozen ("Scanning paused"), material otherwise.
                    .background(model.ambiguous.isEmpty ? AnyShapeStyle(.ultraThinMaterial)
                                                        : AnyShapeStyle(Color.orange.opacity(0.9)),
                                in: Capsule())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                               value: model.activityText)
                    if model.ambiguous.isEmpty {
                        // In look-up mode the tray is noise until something is actually staged —
                        // but staged cards from an earlier session still need their way back.
                        if !model.isLookUpMode || !staging.drafts.isEmpty {
                            StagingTray(staging: staging, store: store,
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

    /// Both scanner settings behind one chip: "Add · MP", or just "Look up".
    ///
    /// Mode and condition are set once per stack and then not touched again, but as two permanent
    /// segmented controls they sat over the camera for the entire session — with the guidance
    /// text, the ring, the tray and Reset, the viewfinder had six things competing with the card
    /// (reported on device 2026-07-26). Collapsed, the frame is left to do its job, and the chip
    /// still states both answers so nothing is hidden — which matters, because the condition
    /// silently prices everything you capture.
    @ViewBuilder private var settingsControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    showingSettings.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(settingsSummary).font(.footnote.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2)
                        .rotationEffect(.degrees(showingSettings ? 180 : 0))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scanner settings, \(settingsSummary)")
            .accessibilityHint(showingSettings ? "Hides the settings" : "Shows mode, condition and source")

            if showingSettings {
                VStack(spacing: 8) {
                    modePicker
                    // Only in Add mode: look-up stages nothing, so a condition for the thing it
                    // isn't recording would be one more control saying nothing.
                    if !model.isLookUpMode {
                        conditionPicker
                        sourcePicker
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// "Add · MP" while staging, "Add · MP · Pulled" once a source is chosen, "Look up" when
    /// nothing is being recorded. The source only appears when set — an absent claim shouldn't
    /// take up room saying it's absent.
    private var settingsSummary: String {
        guard !model.isLookUpMode else { return "Look up" }
        var s = "Add · \(model.stagingCondition.rawValue)"
        if let via = model.stagingVia { s += " · \(via.shortLabel)" }
        return s
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

    /// How this stack was acquired, set once for a whole pack rip. Resets on cold launch, unlike
    /// the two pickers above it: staging at the wrong condition costs a price tier, but staging
    /// at the wrong SOURCE puts a false fact on the card, and nobody re-reads a scanner setting
    /// they set last week.
    private var sourcePicker: some View {
        // A menu, not a segmented control. Five segments of real words don't fit: at
        // `maxWidth: 260` each gets ~52pt and "Bought" rendered as "Boug…" on device
        // (2026-07-27). The condition picker beside it gets away with five because its labels are
        // two and three characters. A menu can't truncate at any Dynamic Type size, and this is
        // set once per pack rip, so the extra tap costs nothing.
        Picker("Source", selection: $model.stagingVia) {
            Text("Not recorded").tag(AcquiredVia?.none)
            ForEach(AcquiredVia.allCases) { Text($0.shortLabel).tag(AcquiredVia?.some($0)) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Source for scanned cards")
        .accessibilityHint("How the cards you're scanning were acquired")
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

/// Fills as the lock gate's confirmation streak builds, so the seconds a slow device spends
/// confirming read as progress rather than a stall. Animated: the steps are ~1.7s apart on an A10
/// and an un-animated jump between two of them is easy to miss entirely.
private struct ConfidenceRing: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 6)
            Circle().trim(from: 0, to: value).stroke(.green, lineWidth: 6)
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("Match confidence")
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
                // The condition this total is priced at lives in the settings chip at the top of
                // the screen, which is always visible — repeating it here was one more line in
                // the viewfinder saying something already on screen.
                Text(staging.totalUsd, format: .currency(code: "USD"))
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
        let base = "\(staging.drafts.count) \(staging.drafts.count == 1 ? "card" : "cards") staged, \(staging.totalUsd.formatted(.currency(code: "USD")))"
        guard let caption = knowledge?.caption else { return base }
        return base + ". Latest: " + caption
    }
}
