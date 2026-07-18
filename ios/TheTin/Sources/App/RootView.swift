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
    @State private var searchModel: SearchModel?
    @State private var showingSettings = false
    private enum Tab: Hashable { case discover, browse, search, tin, scan }
    // The tin is the product's home ("daily check-ins"), so launch there once it has cards;
    // an empty tin (first run) opens on Discover so there's something to see.
    @State private var selection: Tab =
        UserDefaults.standard.bool(forKey: "hasCards") ? .tin : .discover
    /// Path for the Tin tab's stack, so a notification tap can push WantedRoute programmatically.
    @State private var tinPath = NavigationPath()
    @State private var consumedRouteToken = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DiscoverView(store: store, collection: collection, wants: model.wants)
                    .fundingBanner(model: model, store: store)
            }
            .tabItem { Label("Discover", systemImage: "sparkles") }
            .tag(Tab.discover)

            NavigationStack {
                BrowseView(store: store, entries: collection.entries, collection: collection, wants: model.wants)
                    .fundingBanner(model: model, store: store)
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
                .fundingBanner(model: model, store: store)
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
                    .sheet(isPresented: $showingSettings) { SettingsView(app: model) }
                    .fundingBanner(model: model, store: store)
            }
            .tabItem { Label("The Tin", systemImage: "square.stack.3d.up") }
            .tag(Tab.tin)

            NavigationStack {
                ScanTabContainer(store: store, collection: collection)
                    .fundingBanner(model: model, store: store)
            }
            .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            .tag(Tab.scan)
        }
        .task {
            if searchModel == nil { searchModel = SearchModel(store: store) }
            consumeWishlistRoute() // cold launch from a tap: token bumped before we appeared
        }
        .onChange(of: model.wishlistRouteToken) { consumeWishlistRoute() }
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
}

/// Anchors the offline banner + always-on support bar directly under a tab's navigation bar.
/// Must live INSIDE the NavigationStack: a TabView-level `safeAreaInset` lets the child nav bars
/// draw over it (it was covering the Discover section headers).
private extension View {
    func fundingBanner(model: AppModel, store: CatalogStore) -> some View {
        modifier(FundingBanner(model: model, store: store))
    }
}

private struct FundingBanner: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let store: CatalogStore

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
                if let progress = model.catalogDownloadProgress {
                    UpdateToast(progress: progress)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: model.catalogDownloadProgress == nil)
    }
}

/// Bottom card toast (approved mockup A) shown while a new daily catalog artifact is actually
/// downloading — never for the sub-second already-current check, see
/// `CatalogUpdater.ensureLatest(onProgress:)`. Byte-accurate % against the manifest's sizeBytes.
private struct UpdateToast: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("Updating card data…")
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
