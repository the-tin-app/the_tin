import SwiftUI

/// Camera preview + coverage ring + guidance + ambiguous chooser + a live staging tray
/// (count, running value, haptic) with a Review entry point. Drives `ScanModel.run`.
struct ScanView: View {
    @Bindable var model: ScanModel
    let staging: ScanStagingStore
    let collection: CollectionModel
    let store: CatalogStore
    let source: AVCaptureFrameSource
    @State private var showingReview = false

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
                Spacer()
                VStack(spacing: 8) {
                    CoverageRing(value: model.coverage)
                    // Amber while a chooser is frozen ("Scanning paused"), material otherwise.
                    Text(model.guidance).font(.headline).padding(8)
                        .background(model.ambiguous.isEmpty ? AnyShapeStyle(.ultraThinMaterial)
                                                            : AnyShapeStyle(Color.orange.opacity(0.9)),
                                    in: Capsule())
                    if model.ambiguous.isEmpty {
                        StagingTray(staging: staging, store: store) { showingReview = true }
                    } else {
                        // Variant A (approved 2026-07-15): bottom sheet, 2×2 card-image grid.
                        AmbiguousChooser(model: model, options: model.ambiguous)
                    }
                }
            }.padding()
        }
        .sensoryFeedback(.success, trigger: staging.drafts.count)
        .sheet(isPresented: $showingReview) {
            NavigationStack { StagingReviewView(staging: staging, collection: collection, store: store) }
        }
        .task { await model.run(source: source) }
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
    let onReview: () -> Void
    private var latestCard: CardRecord? {
        guard let id = staging.drafts.first?.cardId else { return nil }
        return try? store.card(id: id)
    }
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail of the most-recent capture = instant "got the right card?" glance.
            if staging.drafts.first != nil {
                CardImageView(card: latestCard, quality: "low").frame(width: 34)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "tray.full").imageScale(.large)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(staging.drafts.count) card](inflect: true) staged").font(.subheadline.bold())
                Text(staging.totalUsd, format: .currency(code: "USD"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(staging.drafts.count) \(staging.drafts.count == 1 ? "card" : "cards") staged, \(staging.totalUsd.formatted(.currency(code: "USD")))")
            Spacer()
            Button("Review") { onReview() }
                .buttonStyle(.borderedProminent)
                .disabled(staging.drafts.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
