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
    @State private var selection: Tab = .discover
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
                CollectionView(model: collection, store: store, wants: wants)
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
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if model.network.isOffline {
                    OfflineBanner(asOf: model.catalogState?.priceAsOf ?? (try? store.priceAsOf()) ?? nil)
                }
                FundingBar(funding: model.funding)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress = model.catalogDownloadProgress {
                UpdateToast(progress: progress)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.catalogDownloadProgress == nil)
    }
}

/// Bottom card toast (approved mockup A) shown while a new daily catalog artifact is actually
/// downloading — never for the sub-second already-current check, see
/// `CatalogUpdater.ensureLatest(onProgress:)`. Byte-accurate % against the manifest's sizeBytes.
private struct UpdateToast: View {
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
            .foregroundStyle(.white)
            ProgressView(value: progress)
                .tint(.blue)
                .animation(.linear(duration: 0.2), value: progress)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.17, alpha: 0.95)
                : UIColor(white: 0.11, alpha: 0.92)
        }), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 9, y: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .foregroundStyle(.white)
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
                       ? "Replace current collection?" : "iCloud Backup Found",
                   isPresented: $presented, presenting: offer) { offer in
                Button("Restore",
                       role: offer.requiresOverwriteConfirmation ? ButtonRole.destructive : nil) {
                    Task { await backup.acceptRestore(offer) }
                }
                Button("Not Now", role: .cancel) { backup.restoreOffer = nil }
            } message: { offer in
                Text(offer.requiresOverwriteConfirmation
                     ? "Your collection is no longer empty. Restoring replaces everything in The Tin with the \(offer.entryCount)-card backup from \(dateText(offer))."
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
