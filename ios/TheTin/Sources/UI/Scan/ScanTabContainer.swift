import SwiftUI

/// Hosts the live scanner: renders the pack states, and once the pack is installed and the
/// Matcher builds, enters `ScanView` backed by a persisted staging tray.
///
/// The pack itself is owned by `ScannerPackModel` above the tab, so a download started here
/// keeps running (and stays watchable) from anywhere in the app.
struct ScanTabContainer: View {
    let store: CatalogStore
    let collection: CollectionModel
    /// Feeds the scanner's "on your wishlist" signal; nil in contexts without a wishlist.
    var wants: WantsModel? = nil
    let pack: ScannerPackModel
    /// Only for the "you're on cellular" confirmation before starting. The auto-pause once a
    /// transfer is running lives in `ScannerPackModel`, which polls the monitor directly —
    /// driving it from a SwiftUI `onChange` here never fired on device.
    let network: NetworkMonitor
    @State private var source = AVCaptureFrameSource()
    /// Owned by `MainTabView`, not here: a trade's incoming cards land in the same tray, and two
    /// `persisted()` instances over one file would each erase the other's cards.
    let staging: ScanStagingStore
    /// Built ONCE and held here, never constructed in `body`.
    ///
    /// It used to be `ScanView(model: makeScanModel(…))` inline, so every body re-evaluation minted
    /// a fresh `ScanModel` — and a fresh `ScanPipeline`/`ScanSession` with it. `ScanView.task` has
    /// no `id:`, so it is never restarted: it kept driving model #1 while the view rendered model
    /// #N. The pipeline then fed a model nothing displayed and the view displayed a model nothing
    /// fed. A chooser or look-up card latched on the orphan wedged `handle(_:)` permanently, with
    /// no chooser on screen to tap and a Reset button wired to the wrong object — the scanner logs
    /// locks and stages nothing until you leave the tab and come back, which rebinds the task.
    /// This container sits directly in `RootView.body` beside the toast and funding modifiers, so
    /// a re-render mid-scan needs nothing more than a toast. Diagnosed on an iPad, 2026-07-27.
    @State private var model: ScanModel?
    @State private var reviewingStaged = false
    @State private var confirmingUpdateOverCellular = false

    var body: some View {
        content
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            // Re-check on arrival, so the update banner appears on a running app rather than
            // only after a cold launch. Cheap: `refresh()` reuses an already-built matcher.
            .task { await pack.refresh() }
            .sheet(isPresented: $reviewingStaged) {
                NavigationStack {
                    StagingReviewView(staging: staging, collection: collection, store: store, wants: wants)
                }
            }
            .confirmationDialog("Download over cellular?", isPresented: $confirmingUpdateOverCellular,
                                titleVisibility: .visible) {
                Button("Download now") { pack.startDownload(allowingExpensive: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You're not on Wi-Fi. This may count against your data plan — you can pause and resume anytime, and the scanner keeps working meanwhile.")
            }
    }

    /// The tray is the scanner's, but the scanner is not its only writer: executing a trade puts
    /// the cards you took straight into it. Without this, a user who never downloads the ~500 MB
    /// pack has their traded-for cards sitting safely on disk with no surface anywhere in the app.
    @ViewBuilder private var content: some View {
        if pack.isScannerUsable {
            // Any banner here sits ABOVE the live viewfinder rather than replacing it: with a
            // working pack installed there is never a reason to take the camera away.
            VStack(spacing: 0) {
                packUpdateBanner
                packContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if staging.drafts.isEmpty {
            packContent
        } else {
            VStack(spacing: 0) {
                stagedBanner
                packContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Tells you a newer pack exists, on the one screen where it matters — the scanner is the
    /// only thing the pack affects, and Settings was previously the only place that said so.
    ///
    /// Not shown while the transfer runs: that is the toast's job, and it follows you out of the
    /// tab. Shown while PAUSED, though, or a parked update would be unresumable from here.
    @ViewBuilder private var packUpdateBanner: some View {
        if case .paused(_, let reason) = pack.phase {
            banner(title: reason == .cellular ? "Update paused — you're on cellular"
                                              : "Scanner update paused",
                   caption: "Your progress is saved.",
                   action: reason == .cellular ? "Resume anyway" : "Resume") {
                pack.startDownload(allowingExpensive: reason == .cellular)
            }
        } else if pack.updateAvailable, !pack.isDownloading {
            banner(title: "New scanner pack available",
                   caption: newPackCaption,
                   action: "Update") {
                if network.isExpensive { confirmingUpdateOverCellular = true } else { pack.startDownload() }
            }
        }
    }

    /// Names the cost, because tapping this spends a few hundred MB. `publishedBytes` is nil only
    /// when the manifest hasn't been read this launch, so it degrades to the honest vaguer line.
    private var newPackCaption: String {
        guard let bytes = pack.publishedBytes else { return "Scans more cards. Best on Wi-Fi." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "Scans more cards. \(size), best on Wi-Fi."
    }

    private func banner(title: String, caption: String, action: String,
                        perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").imageScale(.large).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var stagedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").imageScale(.large).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(staging.drafts.count) card](inflect: true) waiting")
                    .font(.subheadline.bold())
                Text("Cards you traded for. File them into your tin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { reviewingStaged = true }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.thinMaterial)
    }

    @ViewBuilder private var packContent: some View {
        switch pack.phase {
        case .checking:
            TinLoadingView(label: "Preparing scanner…").task { await pack.refresh() }
        case .notInstalled:
            ScannerPackSetupView(pack: pack, isExpensive: network.isExpensive)
        // The download wall belongs to a FIRST install only. With a usable pack installed the
        // transfer is an update running alongside it, so the viewfinder stays and the toast
        // reports progress — `isScannerUsable` is checked before the phase for exactly that.
        case .downloading(let progress) where !pack.isScannerUsable:
            ScannerPackProgressView(pack: pack, progress: progress, paused: nil)
        case .paused(let progress, let reason) where !pack.isScannerUsable:
            ScannerPackProgressView(pack: pack, progress: progress, paused: reason)
        case .downloading, .paused:
            liveScanner
        case .unavailable(let msg):
            VStack(spacing: 12) {
                ContentUnavailableView("Scanner unavailable", systemImage: "camera.metering.unknown",
                                       description: Text(msg))
                Button("Retry") { pack.retry() }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            liveScanner
        }
    }

    @ViewBuilder private var liveScanner: some View {
        if let model {
            ScanView(model: model, staging: staging,
                     collection: collection, store: store, source: source, wants: wants)
        } else if let matcher = pack.matcher, let index = pack.index {
            // Assigned from a task rather than built in the branch above: `body` must not
            // construct it (see `model`), and `CardDetector`'s CIContext is not free enough
            // to mint and throw away on every re-render.
            TinLoadingView().task { model = makeScanModel(matcher, index: index) }
        } else {
            TinLoadingView()
        }
    }

    private func makeScanModel(_ matcher: Matcher, index: CandidateIndex) -> ScanModel {
        ScanModel(matcher: matcher, detector: CardDetector(),
                  textGate: TextGate(index: index), narrowing: index, staging: staging, store: store)
    }
}

/// First contact with the scanner. Leads with what the feature does — the download is a cost,
/// not the headline, and the previous copy put the bill first and buried the benefit in a
/// footnote. The size comes from the server manifest rather than a hardcoded string.
struct ScannerPackSetupView: View {
    let pack: ScannerPackModel
    let isExpensive: Bool
    @State private var confirmingCellular = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Identify cards with your camera")
                .font(.headline).multilineTextAlignment(.center)
            Text("Point at a card and The Tin names it — no typing, no searching. Works offline once it's set up.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Set up scanner") {
                if isExpensive { confirmingCellular = true } else { pack.startDownload() }
            }
            .buttonStyle(.borderedProminent)

            Text(sizeCaption)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .confirmationDialog("Download over cellular?", isPresented: $confirmingCellular,
                            titleVisibility: .visible) {
            Button("Download now") { pack.startDownload(allowingExpensive: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're not on Wi-Fi. \(downloadSize) may count against your data plan. You can pause and resume anytime.")
        }
    }

    private var downloadSize: String {
        pack.publishedBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            ?? "This download"
    }

    private var sizeCaption: String {
        guard let bytes = pack.publishedBytes else {
            return "One-time download, best on Wi-Fi. You can pause and resume it anytime."
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "One-time \(size) download, best on Wi-Fi. You can pause and resume it anytime."
    }
}

/// In-progress / parked download. Deliberately not a blocking spinner: the download keeps running
/// while the user browses, and the toast follows them, so this screen says so out loud.
struct ScannerPackProgressView: View {
    let pack: ScannerPackModel
    let progress: FingerprintDownloadProgress
    /// nil while actively downloading; the reason when parked.
    let paused: ScannerPackModel.PauseReason?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress.fraction).frame(maxWidth: 260)
                // Same reason as the toast: a bar at a hard 0 looks stalled, and on a slow link
                // the first bytes of a ~568 MB pack can be a long wait.
                .opacity(progress.bytesDone > 0 ? 1 : 0.35)
            HStack(spacing: 7) {
                if progress.bytesDone == 0, paused == nil { ProgressView().controlSize(.mini) }
                Text(progress.bytesDone > 0 ? progress.byteSummary : "Starting…")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }

            if let paused {
                Text(paused == .cellular
                     ? "Paused — you're on cellular."
                     : "Paused. Your progress is saved.")
                    .font(.subheadline).multilineTextAlignment(.center)
                Button(paused == .cellular ? "Resume anyway" : "Resume") {
                    pack.startDownload(allowingExpensive: paused == .cellular)
                }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Setting up the scanner. Keep using The Tin — this carries on in the background.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Pause") { pack.pause() }.buttonStyle(.bordered)
            }
        }
        .padding(28)
        // Fill the tab. Without this the view sizes to its content, and the funding bar —
        // attached as a top safeAreaInset — rides down with it into the middle of the screen
        // instead of sitting under the navigation bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
