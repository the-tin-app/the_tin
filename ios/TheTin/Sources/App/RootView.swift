import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.phase {
        case .launching:
            TinLoadingView(label: "Starting…")
        case .downloadingCatalog:
            VStack(spacing: 12) {
                TinLoadingView()
                Text("Downloading card catalog…").font(.headline)
                Text("One-time download — after this, browse and search work fully offline.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.retry() } }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            if let store = model.store, let collection = model.collection {
                MainTabView(store: store, collection: collection, wants: model.wants, model: model)
                    .restoreBackupPrompt(model.backup)
            }
        }
    }
}

private struct MainTabView: View {
    let store: CatalogStore
    let collection: CollectionModel
    let wants: WantsModel?
    @Bindable var model: AppModel
    /// Owned here, not in the Scan tab: the pack download must be startable from Settings and the
    /// first-run prompt, must keep running when the user leaves Scan, and must stay watchable
    /// from every tab.
    @State private var pack: ScannerPackModel
    @State private var searchModel: SearchModel?
    @State private var showingSettings = false
    /// The scan tray, owned HERE rather than in the Scan tab.
    ///
    /// A trade's incoming cards land in it too, and `ScanStagingStore.persisted()` reads the same
    /// file — so two instances would each hold half the tray and the last write would erase the
    /// other's cards. One instance, two writers.
    @State private var staging = ScanStagingStore.persisted()

    init(store: CatalogStore, collection: CollectionModel, wants: WantsModel?, model: AppModel) {
        self.store = store
        self.collection = collection
        self.wants = wants
        self.model = model
        _pack = State(wrappedValue: ScannerPackModel.live(catalogStore: store, network: model.network))
    }
    // Browse is no longer a tab: it lives behind Discover, which already had a (different)
    // browse row of its own. The freed slot went to Movers — the daily check-in this app had
    // no home for (2026-07-24).
    private enum Tab: Hashable { case discover, movers, search, tin, scan }
    // The tin is the product's home ("daily check-ins"), so launch there once it has cards;
    // an empty tin (first run) opens on Discover so there's something to see.
    @State private var selection: Tab =
        UserDefaults.standard.bool(forKey: "hasCards") ? .tin : .discover
    /// Path for the Tin tab's stack, so Siri and the Action button can push programmatically.
    @State private var tinPath = NavigationPath()
    /// Path for the Discover stack, so the empty tin's "Browse sets" CTA lands ON the catalog
    /// rather than on Discover's home with the catalog somewhere below the fold.
    @State private var discoverPath = NavigationPath()
    @State private var consumedCardToken = 0
    @State private var consumedTradeToken = 0
    @State private var consumedIntentToken = 0
    @State private var consumedImportToken = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $discoverPath) {
                DiscoverView(store: store, collection: collection, wants: model.wants,
                             goals: model.setGoals)
                    // Install day is when someone is most likely on home Wi-Fi — the right moment
                    // to mention the scanner. A dismissible banner, never a modal: stacking a
                    // second large download behind the catalog's would make first run worse.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ScannerPackPrompt(pack: pack, isExpensive: model.network.isExpensive) {
                            selection = .scan
                        }
                    }
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            .appToasts(model: model, pack: pack)
            .tabItem { Label("Discover", systemImage: "sparkles") }
            .tag(Tab.discover)

            NavigationStack {
                MoversView(model: collection, store: store, wants: model.wants)
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            .appToasts(model: model, pack: pack)
            .tabItem { Label("Movers", systemImage: "chart.line.uptrend.xyaxis") }
            .tag(Tab.movers)

            NavigationStack {
                Group {
                    if let searchModel {
                        SearchView(model: searchModel, store: store, collection: collection, wants: wants)
                    } else {
                        TinLoadingView()
                    }
                }
                .fundingBanner(model: model, store: store, pack: pack)
            }
            .appToasts(model: model, pack: pack)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack(path: $tinPath) {
                CollectionView(model: collection, store: store, wants: wants,
                               onGetStarted: { tab in
                                   switch tab {
                                   case .scan: selection = .scan
                                   // There is no Browse tab any more — push the catalog onto
                                   // Discover's stack so the CTA lands ON it, not near it.
                                   case .browse:
                                       discoverPath.append(BrowseRoute())
                                       selection = .discover
                                   }
                               },
                               scannerReady: pack.phase == .ready,
                               // Searching your tin used to dead-end in a note telling you to go
                               // to another tab. Now it takes you there, carrying the query.
                               onSearchCatalog: { query in
                                   searchModel?.text = query
                                   selection = .search
                               },
                               goals: model.setGoals,
                               openPager: { id in tinPath.append(TinPagerRoute(groupId: id)) },
                               staging: staging,
                               backup: model.backup,
                               // Filing the cards you just took is the obvious next step, so land
                               // on the tray rather than leaving it to be discovered later.
                               onExecutedTrade: { selection = .scan },
                               // The gear belongs to CollectionView's own toolbar. Applying it
                               // here as a second `.toolbar` is what lost it on iPadOS 18.
                               onOpenSettings: { showingSettings = true })
                    .sheet(isPresented: $showingSettings) { SettingsView(app: model, pack: pack) }
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            .appToasts(model: model, pack: pack)
            .tabItem { Label("The Tin", systemImage: "square.stack.3d.up") }
            .tag(Tab.tin)

            NavigationStack {
                ScanTabContainer(store: store, collection: collection, wants: model.wants,
                                 pack: pack, network: model.network, staging: staging)
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            // Shown here only when the Scan tab is NOT already showing the full-screen download
            // wall — i.e. an update over a working pack, where the viewfinder stays live and the
            // toast is the only progress on screen. A first install would double up.
            .appToasts(model: model, pack: pack, showsScannerToast: pack.isScannerUsable)
            .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            .tag(Tab.scan)
        }
        .task {
            if searchModel == nil { searchModel = SearchModel(store: store) }
            consumeCardRoute()
            consumeIntentRoute()   // …same for a cold launch from Siri or the Action button
            await pack.refresh()   // learn the pack's state once, for Settings and the prompt
        }
        .onChange(of: model.importRouteToken) { consumeImportRoute() }
        .onChange(of: model.cardRouteToken) { consumeCardRoute() }
        .onChange(of: model.tradeRouteToken) { consumeTradeRoute() }
        // A shared WANT link belongs in the browser. `UIApplication.open` called from the app that
        // owns the universal link opens Safari rather than bouncing back here — which is the whole
        // point, since the association file cannot tell a want link from a trade link.
        .onChange(of: model.externalURLToken) {
            if let url = model.pendingExternalURL { UIApplication.shared.open(url) }
        }
        .onChange(of: model.intentRouteToken) { consumeIntentRoute() }
        // Collection writes can fail from any tab (card detail lives under Browse/Search too),
        // so the failure alert hangs off the TabView, not the Tin stack.
        .alert("Save failed", isPresented: Binding(
            get: { collection.writeError != nil },
            set: { if !$0 { collection.writeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(collection.writeError?.message ?? "")
        }
    }

    /// A CSV opened in The Tin from Files / AirDrop / a share sheet. Settings owns the whole
    /// import flow — picker, progress, result sheet, skipped-rows export — so opening it is the
    /// honest destination rather than duplicating any of that at the root.
    private func consumeImportRoute() {
        guard model.importRouteToken > consumedImportToken, model.pendingImportURL != nil else { return }
        consumedImportToken = model.importRouteToken
        showingSettings = true
    }

    private func consumeIntentRoute() {
        guard model.intentRouteToken > consumedIntentToken,
              let route = model.pendingIntentRoute else { return }
        consumedIntentToken = model.intentRouteToken
        switch route {
        case .scan:
            selection = .scan
        case .search(let query):
            // searchModel is created in the same `.task` immediately above this call, so it
            // exists by the time a cold-launch intent is consumed.
            searchModel?.text = query
            selection = .search
        }
    }

    private func consumeCardRoute() {
        guard model.cardRouteToken > consumedCardToken, let id = model.pendingCardId else { return }
        consumedCardToken = model.cardRouteToken
        // A deep link can carry an unknown id (garbage link, or a card missing from an older
        // local catalog). The CardID destination has no not-found branch, so pushing it would
        // land on a blank screen — only navigate when the card actually resolves.
        guard (try? store.card(id: id)) != nil else { return }
        selection = .tin
        tinPath.append(CardID(raw: id))
    }

    /// Someone's shared trade list, opened in the app: land on a live trade with their side
    /// already filled in.
    ///
    /// The payload travels ON the route rather than being read out of `AppModel` by the screen, so
    /// one destination serves both a deep link and a trade you started yourself with nothing in it.
    private func consumeTradeRoute() {
        guard model.tradeRouteToken > consumedTradeToken,
              let offer = model.pendingTradeOffer else { return }
        consumedTradeToken = model.tradeRouteToken
        selection = .tin
        tinPath.append(TradeSessionRoute(offer: offer))
    }
}

/// Anchors the offline banner + always-on support bar directly under a tab's navigation bar.
/// Must live INSIDE the NavigationStack: a TabView-level `safeAreaInset` lets the child nav bars
/// draw over it (it was covering the Discover section headers).
private extension View {
    func fundingBanner(model: AppModel, store: CatalogStore, pack: ScannerPackModel) -> some View {
        modifier(FundingBanner(model: model, store: store, pack: pack))
    }

    /// Attach to the tab's `NavigationStack`, never to its root view — see `AppToasts`.
    ///
    /// `showsScannerToast: false` on the Scan tab — that screen already renders the download
    /// full-size, so the toast would be a second copy of the same bar sitting on top of its
    /// Pause button. The toast exists for the other tabs, so progress follows you out of Scan.
    func appToasts(model: AppModel, pack: ScannerPackModel,
                   showsScannerToast: Bool = true) -> some View {
        modifier(AppToasts(model: model, pack: pack, showsScannerToast: showsScannerToast))
    }
}

private struct FundingBanner: ViewModifier {
    let model: AppModel
    let store: CatalogStore
    let pack: ScannerPackModel

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if model.network.isOffline {
                        OfflineBanner(asOf: model.catalogState?.priceAsOf ?? (try? store.priceAsOf()) ?? nil)
                    }
                    if model.reducedData {
                        ReducedDataBanner(installedTier: model.catalogState?.tier)
                    }
                    FundingBar(funding: model.funding)
                }
            }
    }
}

/// The bottom toasts — undo, catalog update, scanner download.
///
/// Applied to the tab's `NavigationStack`, NOT to the stack's root view. Attached to the root, an
/// overlay is covered the moment anything is pushed: you delete a card inside a divider
/// (`GroupDetailView`), and the undo toast renders on the hidden root screen behind it. The Tin's
/// write-failure alert already lives at this level for the same reason — collection writes happen
/// from screens all over the app, so the response to one can't live on any single screen.
///
/// Pinning to the bottom of the NavigationStack puts the toast just above the tab bar (the stack's
/// frame stops there), which is also clear of the home indicator.
private struct AppToasts: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let pack: ScannerPackModel
    let showsScannerToast: Bool

    func body(content: Content) -> some View {
        content
            // `safeAreaInset`, not `overlay`: a TabView lays its content out BEHIND the tab bar and
            // communicates the bar via safe-area insets, so an overlay pinned to the bottom of the
            // NavigationStack renders underneath the tab bar and is never seen. safeAreaInset is
            // the modifier that means "place this in the safe area at the bottom of this
            // container" — it clears the tab bar, and being attached to the stack it stays put
            // when a screen is pushed.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if let collection = model.collection, let undoable = collection.undoable {
                        UndoToast(undoable: undoable) {
                            Task { await collection.undoLastDelete() }
                        }
                    }
                    if let progress = model.catalogDownloadProgress {
                        UpdateToast(label: "Updating card data…", progress: progress)
                    }
                    // Follows the user out of the Scan tab — the whole point of hoisting the
                    // download is that they can walk away from it.
                    if showsScannerToast, case .downloading(let p) = pack.phase {
                        // "Setting up" is a lie once a pack is installed and scanning — that
                        // transfer is an update running behind a scanner that already works.
                        UpdateToast(label: "\(pack.isScannerUsable ? "Updating" : "Setting up") scanner… \(p.byteSummary)",
                                    progress: p.fraction)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: model.catalogDownloadProgress == nil)
    }
}

/// One-line invitation to set up the scanner, shown on Discover until it's taken or dismissed.
/// Deliberately a banner in the same vocabulary as the offline / reduced-data banners rather
/// than a modal — it must be ignorable.
private struct ScannerPackPrompt: View {
    let pack: ScannerPackModel
    let isExpensive: Bool
    let onOpen: () -> Void
    @AppStorage(AppConfig.scannerPromptDismissedKey) private var dismissed = false

    private var shouldShow: Bool {
        if dismissed { return false }
        return pack.phase == .notInstalled
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add cards with your camera").font(.caption.bold())
                    Text(sizeCaption).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button("Set up", action: onOpen).font(.caption.bold()).buttonStyle(.bordered)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss scanner setup")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    private var sizeCaption: String {
        guard let bytes = pack.publishedBytes else { return "One-time download, best on Wi-Fi" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return isExpensive ? "One-time \(size) download — best on Wi-Fi"
                           : "One-time \(size) download"
    }
}

/// Bottom card toast (approved mockup A) shown while a new daily catalog artifact is actually
/// downloading — never for the sub-second already-current check, see
/// `CatalogUpdater.ensureLatest(onProgress:)`. Byte-accurate % against the manifest's sizeBytes.
/// Also carries the scanner pack download, so leaving the Scan tab doesn't lose sight of it.
private struct UpdateToast: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let progress: Double

    /// Nothing has landed yet. A determinate bar pinned at 0% reads as a stalled download, and on
    /// a slow link the pack's first chunk is minutes away — so say "working" instead of "0%".
    private var isIndeterminate: Bool { progress <= 0 }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(label)
                Spacer()
                if isIndeterminate {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            ProgressView(value: progress)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                .opacity(isIndeterminate ? 0.35 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Flat Tin Rule: chrome earns separation from a system material, never a shadow.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Six seconds to change your mind. Same material vocabulary as `UpdateToast` so the bottom of
/// the screen has one voice; auto-dismisses, because an undo you have to dismiss is a dialog.
private struct UndoToast: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let undoable: CollectionModel.UndoableDelete
    let onUndo: () -> Void
    /// Share of the undo window still left, 1 → 0. Drives the countdown bar.
    @State private var remaining: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(undoable.message)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Undo", action: onUndo)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            // How long you have left. The offer used to vanish with no warning, so the only way
            // to learn the window was to miss it.
            //
            // Driven off `undoable.expiresAt`, not a local timer: if SwiftUI rebuilds this toast
            // mid-window the bar picks up where the clock actually is instead of restarting full.
            // A scaled Capsule rather than ProgressView so it reads as a depleting bar, not a
            // task that's loading.
            Capsule()
                .fill(.tint)
                .frame(height: 3)
                .scaleEffect(x: remaining, y: 1, anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)   // the label below already says undo is available
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Not gated on Reduce Motion: this is the state itself, not decoration. A 3pt bar
        // shrinking is not the kind of motion that setting exists to suppress, and freezing it
        // would leave a bar that lies about how long is left.
        .task(id: undoable.id) {
            let left = max(0, undoable.expiresAt.timeIntervalSinceNow)
            remaining = CGFloat(left / CollectionModel.undoWindowSeconds)
            withAnimation(.linear(duration: left)) { remaining = 0 }
        }
        // Flat Tin Rule: chrome earns separation from a system material, never a shadow.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: undoable.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(undoable.message). Undo available.")
    }
}

/// Shown while the installed catalog is a poorer tier than the one the user picked — e.g. a tier
/// switch that didn't finish, or a legacy install that predates the current choice. Every backup
/// origin (R2 included) now carries all three tiers, so this is never a "which server answered"
/// problem — otherwise missing history/grades would read as a bug rather than a state.
private struct ReducedDataBanner: View {
    /// `AppModel.catalogState?.tier`, the raw tier string of what's actually installed.
    let installedTier: String?

    private var tierTitle: String? {
        installedTier.flatMap { CatalogTier(rawValue: $0)?.title }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.icloud")
            Text(tierTitle.map { "Showing \($0) card data — switch it in Settings" }
                 ?? "Showing a smaller catalog than you chose — switch it in Settings")
        }
        .font(.caption.bold())
        .padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.9))
        .foregroundStyle(.black)
    }
}

private struct OfflineBanner: View {
    let asOf: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text(asOf.map { "Offline — prices as of \($0)" } ?? "Offline")
        }
        .font(.caption.bold())
        .padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(.orange.opacity(0.9))
        .foregroundStyle(.black) // white-on-orange fails contrast; black is ~9.5:1
    }
}

/// Presents the launch restore prompt whenever `BackupService` publishes an offer. When
/// acceptance detects the collection is no longer empty (first-scan race), the service
/// re-publishes the offer with `requiresOverwriteConfirmation` and this re-presents it as a
/// destructive warn-and-confirm.
private struct RestoreBackupPrompt: ViewModifier {
    let backup: BackupService
    @State private var offer: BackupService.RestoreOffer?
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: backup.restoreOffer, initial: true) { _, new in
                if let new { offer = new; presented = true }
            }
            .alert(offer?.requiresOverwriteConfirmation == true
                       ? "Replace everything in your tin?" : "iCloud Backup Found",
                   isPresented: $presented, presenting: offer) { offer in
                Button("Restore",
                       role: offer.requiresOverwriteConfirmation ? ButtonRole.destructive : nil) {
                    Task { await backup.acceptRestore(offer) }
                }
                Button("Not Now", role: .cancel) { backup.restoreOffer = nil }
            } message: { offer in
                Text(offer.requiresOverwriteConfirmation
                     ? "Your tin is no longer empty. Restoring replaces everything in it with the \(offer.entryCount)-card backup from \(dateText(offer))."
                     : "Restore \(offer.entryCount) cards from the iCloud backup made \(dateText(offer))?")
            }
    }

    private func dateText(_ offer: BackupService.RestoreOffer) -> String {
        offer.exportedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

private extension View {
    @ViewBuilder
    func restoreBackupPrompt(_ backup: BackupService?) -> some View {
        if let backup { modifier(RestoreBackupPrompt(backup: backup)) } else { self }
    }
}
