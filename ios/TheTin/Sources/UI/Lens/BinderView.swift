import SwiftUI

/// The virtual binder: one question, a handful of guided photographs, then a binder you flip through.
///
/// ⚠️ This IS a `switch`, and it is the one place in this feature where that is correct. A `switch`
/// in a `@ViewBuilder` compiles to `_ConditionalContent` per case, so moving between cases destroys
/// and recreates the subtree — which is a bug when an *incidental* state change does it (that shipped
/// once in `ScanTabContainer` and cost a 3–5 s white screen at each end of a pack download). Here the
/// three cases genuinely differ in whether a camera session should exist at all, and the user asked
/// for every transition. Setup has no camera; browsing must NOT hold one open in a shop.
struct BinderView: View {
    @Bindable var model: BinderModel
    let source: LensPhotoSource
    let store: CatalogStore

    var body: some View {
        phaseContent
            // ⚠️ Here, not inside `.browsing`. A scan restored from the cache arrives with entries and
            // no metadata, and the grid is grey rectangles until this runs.
            .task(id: model.scan.entries.count) { await model.hydrate() }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .setup:
            BinderSetupView(shape: model.shape) { model.begin(shape: $0) }
        case .capturing:
            BinderCaptureView(model: model, source: source)
        case .browsing:
            BinderBrowseView(model: model, store: store)
        }
    }
}

/// The only thing between the user and the camera: how many pockets across, and down. No naming, no
/// vendor, no session metadata — every one of those is a tap paid before the first photograph, and
/// the thing being described is a shop's binder that will be different tomorrow.
struct BinderSetupView: View {
    @State private var rows: Int
    @State private var cols: Int
    let onStart: (BinderShape) -> Void

    init(shape: BinderShape, onStart: @escaping (BinderShape) -> Void) {
        _rows = State(initialValue: shape.rows)
        _cols = State(initialValue: shape.cols)
        self.onStart = onStart
    }

    private var shape: BinderShape { BinderShape(rows: rows, cols: cols) }
    private var shots: Int { BinderPlan.tiles(shape: shape, page: 0).count }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("What shape is the binder?").font(.headline)
                Text("Count the pockets on one page.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            pocketPreview

            HStack(spacing: 18) {
                Stepper("\(cols) across", value: $cols, in: BinderShape.range)
                Stepper("\(rows) down", value: $rows, in: BinderShape.range)
            }
            .font(.subheadline)
            .frame(maxWidth: 360)

            // Says the cost before it is paid. Nine shots for a 5×5 page is the risk in this whole
            // feature, and finding it out one shutter press at a time is the bad way to learn it.
            Text("^[\(shots) photo](inflect: true) per page — you'll be guided through them.")
                .font(.footnote).foregroundStyle(.secondary)

            Button("Start") { onStart(shape) }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shape, drawn. Reading "3 across, 3 down" and checking it against the object in your hands
    /// is slower than looking at a picture of it.
    private var pocketPreview: some View {
        VStack(spacing: 4) {
            ForEach(Array(0..<rows), id: \.self) { _ in
                HStack(spacing: 4) {
                    ForEach(Array(0..<cols), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                            .aspectRatio(0.72, contentMode: .fit)
                    }
                }
            }
        }
        .frame(maxHeight: 190)
        .accessibilityLabel("\(cols) pockets across, \(rows) down")
    }
}

/// Guided capture: a 2×2 outline on the live preview, the tile named, and a counter.
///
/// **Manual shutter — no auto-trigger.** Deciding when the shot is good is the user's job and they
/// are better at it than a focus score is.
struct BinderCaptureView: View {
    let model: BinderModel
    let source: LensPhotoSource
    /// Drives the shutter flash. Reported from the device: "there is no UI indication that a photo was
    /// taken — the prompt just changes, which feels weird." A capture is the one moment in this flow
    /// where the user needs to know something happened, and a changed caption is not that.
    @State private var flashing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // ⚠️ The fill and the explicit frame are load-bearing. `CameraPreview` has no intrinsic
            // size, so without them the whole screen collapses to the height of the header overlay and
            // the shutter is nowhere on screen — which is what a simulator shows, and what a user who
            // declined the camera permission would get: a caption and no way to do anything.
            Color.black
            if source.isAvailable {
                CameraPreview(session: source.session)
                TwoByTwoGuide()
            } else {
                ContentUnavailableView("The camera isn't available",
                                       systemImage: "camera.metering.unknown",
                                       description: Text("The Tin needs camera access to photograph a binder. You can grant it in Settings."))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { Color.white.opacity(flashing ? 0.85 : 0).allowsHitTesting(false) }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { controls }
        .clipped()
        // Flash and haptic, both keyed on the shot count rather than on the button action: the shutter
        // press and the photograph arriving are not the same instant, and the feedback belongs to the
        // photograph. `.success` rather than a light tick — a captured page is worth something.
        .sensoryFeedback(.success, trigger: model.shotsTaken)
        .onChange(of: model.shotsTaken) {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.06)) { flashing = true }
            withAnimation(.easeIn(duration: 0.22).delay(0.06)) { flashing = false }
        }
        // ⚠️ `.onAppear`, NOT `.task`. `onDisappear` STOPS the capture session, so it has to be started
        // again on every appearance — and this project has already recorded that a `.task` with no `id:`
        // cannot be relied on to re-fire when a view reappears without being rebuilt. Getting that wrong
        // gives a black preview and a shutter that silently does nothing after one tab switch.
        //
        // `start()` is idempotent, and `capture()` refuses to fire against a session that isn't running,
        // so an early shutter tap is a no-op rather than the AVFoundation crash it would otherwise be.
        .onAppear {
            Task { await source.start() }
            // ⚠️ A pause with no resume leaves every pocket unread forever, showing as nothing at all.
            model.resume()
        }
        .onDisappear { source.stop(); model.cancel() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            if model.isPageComplete {
                Text("Page \(model.page + 1) done").font(.headline)
            } else {
                Text("Frame the \(model.currentTileName) four pockets")
                    .font(.headline).multilineTextAlignment(.center)
                Text(model.progressText).font(.caption).monospacedDigit()
            }
            // Fires only when a capture really came back small. See `deliveredSmallPhoto` — this is
            // the sole visible symptom of a silent macro handoff, which costs a third of the locks.
            if source.deliveredSmallPhoto {
                Text("Low-resolution photo (\(source.megapixelsText)) — move back a little and don't let the lens get too close.")
                    .font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
            // ⚠️ Stated, because the alternative is a shutter that silently does nothing. This used to
            // be a crash: `capturePhoto` raises an NSException for invalid settings and Swift cannot
            // catch it, so the app aborted mid-scan. It is caught now (see `AVSafeCapture.h`) and the
            // refusal has to be visible or the fix just trades a crash for a dead button.
            if let failure = source.captureFailure {
                Text("The camera refused that shot — \(failure). Tell Tomas; this should not happen.")
                    .font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            }
            // DEBUG-only, and it earns its place: "the photo came back small" has several possible
            // causes and one device session was already spent telling them apart by inference.
            if let diagnostic = source.diagnostic {
                Text(diagnostic)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal).padding(.top, 10)
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 12) {
            if model.isWorking {
                Text("Reading…").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            if model.isPageComplete {
                // ⚠️ NOT `.tint(.white)` on the group. That painted a `.borderedProminent` button white
                // AND left its label white — an invisible "Next page", reported from the device. The
                // prominent button keeps the accent fill; only the bordered one is tinted white, where
                // the tint is the outline and the label.
                HStack(spacing: 12) {
                    Button("Next page") { model.nextPage() }
                        .buttonStyle(.borderedProminent)
                    Button("Done") { model.finish() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            } else {
                // Equal-width side slots, so the shutter sits on the centre line whatever the labels
                // say. "Retake last" keeps its space when hidden — a control that appears after the
                // first shot must not shove the shutter sideways mid-page.
                HStack(spacing: 12) {
                    Button("Retake last") { model.retakePrevious() }
                        .opacity(model.tileIndex > 0 ? 1 : 0)
                        .disabled(model.tileIndex == 0)
                        .frame(maxWidth: .infinity)
                    shutter
                    Button("Finish") { model.finish() }
                        .frame(maxWidth: .infinity)
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 16)
    }

    private var shutter: some View {
        Button {
            Task { await model.shoot() }
        } label: {
            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 66, height: 66)
                .background(Circle().fill(.white.opacity(0.25)))
        }
        .disabled(!source.isAvailable)
        .accessibilityLabel("Take the \(model.currentTileName) photo")
    }
}

/// The 2×2 frame guide. Deliberately inset from the edges: extra margin costs nothing — slot
/// snapping discards whatever doesn't land on a pocket — and the main lens cannot focus close enough
/// for a tight 2×2 anyway, which is exactly how the macro handoff happened.
private struct TwoByTwoGuide: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.86, h = geo.size.height * 0.78
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.85), lineWidth: 2)
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
