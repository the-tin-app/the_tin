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

    init(store: CatalogStore, collection: CollectionModel, wants: WantsModel?, model: AppModel) {
        self.store = store
        self.collection = collection
        self.wants = wants
        self.model = model
        _pack = State(wrappedValue: ScannerPackModel.live(catalogStore: store, network: model.network))
    }
    private enum Tab: Hashable { case discover, browse, search, tin, scan }
    // The tin is the product's home ("daily check-ins"), so launch there once it has cards;
    // an empty tin (first run) opens on Discover so there's something to see.
    @State private var selection: Tab =
        UserDefaults.standard.bool(forKey: "hasCards") ? .tin : .discover
    /// Path for the Tin tab's stack, so a notification tap can push WantedRoute programmatically.
    @State private var tinPath = NavigationPath()
    @State private var consumedRouteToken = 0
    @State private var consumedCardToken = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DiscoverView(store: store, collection: collection, wants: model.wants)
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
            .tabItem { Label("Discover", systemImage: "sparkles") }
            .tag(Tab.discover)

            NavigationStack {
                BrowseView(store: store, entries: collection.entries, collection: collection, wants: model.wants)
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
            .tag(Tab.browse)

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
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack(path: $tinPath) {
                CollectionView(model: collection, store: store, wants: wants,
                               onGetStarted: { selection = $0 == .scan ? .scan : .browse },
                               openPager: { id in tinPath.append(TinPagerRoute(groupId: id)) })
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showingSettings = true } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                    .sheet(isPresented: $showingSettings) { SettingsView(app: model, pack: pack) }
                    .fundingBanner(model: model, store: store, pack: pack)
            }
            .tabItem { Label("The Tin", systemImage: "square.stack.3d.up") }
            .tag(Tab.tin)

            NavigationStack {
                ScanTabContainer(store: store, collection: collection, wants: model.wants,
                                 pack: pack, network: model.network)
                    .fundingBanner(model: model, store: store, pack: pack,
                                   showsScannerToast: false)
            }
            .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            .tag(Tab.scan)
        }
        .task {
            if searchModel == nil { searchModel = SearchModel(store: store) }
            consumeWishlistRoute() // cold launch from a tap: token bumped before we appeared
            consumeCardRoute()
            await pack.refresh()   // learn the pack's state once, for Settings and the prompt
        }
        .onChange(of: model.wishlistRouteToken) { consumeWishlistRoute() }
        .onChange(of: model.cardRouteToken) { consumeCardRoute() }
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

    private func consumeWishlistRoute() {
        guard model.wishlistRouteToken > consumedRouteToken else { return }
        consumedRouteToken = model.wishlistRouteToken
        selection = .tin
        tinPath.append(WantedRoute())
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
}

/// Anchors the offline banner + always-on support bar directly under a tab's navigation bar.
/// Must live INSIDE the NavigationStack: a TabView-level `safeAreaInset` lets the child nav bars
/// draw over it (it was covering the Discover section headers).
private extension View {
    /// `showsScannerToast: false` on the Scan tab — that screen already renders the download
    /// full-size, so the toast would be a second copy of the same bar sitting on top of its
    /// Pause button. The toast exists for the other tabs, so progress follows you out of Scan.
    func fundingBanner(model: AppModel, store: CatalogStore, pack: ScannerPackModel,
                       showsScannerToast: Bool = true) -> some View {
        modifier(FundingBanner(model: model, store: store, pack: pack,
                               showsScannerToast: showsScannerToast))
    }
}

private struct FundingBanner: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let store: CatalogStore
    let pack: ScannerPackModel
    let showsScannerToast: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if model.network.isOffline {
                        OfflineBanner(asOf: model.catalogState?.priceAsOf ?? (try? store.priceAsOf()) ?? nil)
                    }
                    if model.reducedData {
                        ReducedDataBanner()
                    }
                    FundingBar(funding: model.funding)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    if let progress = model.catalogDownloadProgress {
                        UpdateToast(label: "Updating card data…", progress: progress)
                    }
                    // Follows the user out of the Scan tab — the whole point of hoisting the
                    // download is that they can walk away from it.
                    if showsScannerToast, case .downloading(let p) = pack.phase {
                        UpdateToast(label: "Setting up scanner… \(p.byteSummary)",
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

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(label)
                Spacer()
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            ProgressView(value: progress)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
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

/// Shown while the installed catalog is a poorer tier than the one the user picked (the
/// casual-only backup source bootstrapped it) — otherwise missing history/grades read as a bug.
private struct ReducedDataBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.icloud")
            Text("Backup card data — price history unavailable")
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
