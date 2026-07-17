import Foundation
import Observation
import os

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case downloadingCatalog
        case ready
        case failed(String)
    }

    enum CatalogSource: String { case selfHosted, firebase }
    enum TierChange: Equatable { case idle, downloading, done, failed(String) }

    private(set) var phase: Phase = .launching
    private(set) var store: CatalogStore?
    private(set) var collection: CollectionModel?
    private(set) var wants: WantsModel?
    private(set) var catalogState: CatalogState?
    /// Which remote served the most recent catalog operation (nil until the first update runs).
    private(set) var activeSource: CatalogSource?
    /// The user's selected tier, mirrored from `AppConfig.catalogTier` so the Settings picker's
    /// checkmark updates reactively after a switch.
    private(set) var currentTier: String = AppConfig.catalogTier
    private(set) var tierChange: TierChange = .idle
    /// Bumped when a price-alert notification tap asks for the wishlist screen; RootView
    /// watches it (tab switch + WantedRoute push). A counter, not a Bool, so a second tap
    /// re-routes even if the first was already consumed.
    private(set) var wishlistRouteToken = 0
    func openWishlist() { wishlistRouteToken += 1 }
    /// iCloud backup of the local collection/wishlist. nil in catalog-only unit tests
    /// (`skipFirebase`) — every consumer must tolerate nil.
    private(set) var backup: BackupService?
    let network = NetworkMonitor()
    /// Create-once local repository instances (see the guard in `start()`): `BackupService`
    /// subscribes to whichever instances exist on first entry, so `retry()` re-entering `start()`
    /// must keep handing it — and `openStore` — the SAME instances, not fresh ones.
    private var repositoryInstance: CollectionRepository?
    private var wantsRepositoryInstance: WantsRepository?

    private var remote: CatalogRemote
    private let fallbackRemote: CatalogRemote?
    private let paths: CatalogPaths
    private let makeRepository: (String) -> CollectionRepository
    private let skipFirebase: Bool // unit tests exercise catalog flow without Firebase
    private let priceAlerts: PriceAlertsService
    private let now: () -> Date // injectable clock for deterministic funding tests
    private var updater: CatalogUpdater { CatalogUpdater(remote: remote, paths: paths) }

    /// The self-hosted NAS catalog remote (App Attest identity), or nil when no self-host URL is
    /// configured. Firebase serves as the operation-level fallback — see `ensureLatestWithFailover`.
    nonisolated static func selfHostedRemote() -> SelfHostedCatalogRemote? {
        guard let url = AppConfig.selfHostBaseURL else { return nil }
        let session = AppAttestSessionProvider(baseURL: url, attestor: DeviceCheckAttestor(),
                                               http: URLSessionHTTPClient(), keys: KeychainStore())
        return SelfHostedCatalogRemote(baseURL: url, session: session, http: URLSessionHTTPClient())
    }

    /// Production wiring: self-host primary (if configured) with Firebase as the operation-level
    /// fallback, else Firebase-only. Failover is atomic per operation — a catalog update runs
    /// entirely against one source (manifest + artifact together), never mixing the two sources'
    /// version-specific artifact paths.
    @MainActor static func makeDefault(skipFirebase: Bool) -> AppModel {
        let firebase = HTTPCatalogRemote(baseURL: AppConfig.catalogBaseURL)
        if let selfHosted = selfHostedRemote() {
            return AppModel(remote: selfHosted, fallback: firebase, skipFirebase: skipFirebase)
        }
        return AppModel(remote: firebase, skipFirebase: skipFirebase)
    }

    init(remote: CatalogRemote = HTTPCatalogRemote(baseURL: AppConfig.catalogBaseURL),
         fallback: CatalogRemote? = nil,
         paths: CatalogPaths = .default(),
         makeRepository: @escaping (String) -> CollectionRepository = { _ in LocalCollectionRepository() },
         skipFirebase: Bool = false,
         priceAlerts: PriceAlertsService = PriceAlertsService(),
         now: @escaping () -> Date = { Date() }) {
        self.remote = remote
        self.fallbackRemote = fallback
        self.paths = paths
        self.makeRepository = makeRepository
        self.skipFirebase = skipFirebase
        self.priceAlerts = priceAlerts
        self.now = now
    }

    /// Atomic per-source catalog update: run the whole update (manifest + artifact) against the
    /// primary source; on any failure retry the whole update against the fallback. Never mixes a
    /// manifest from one source with an artifact download from another — their version-specific
    /// paths are not interchangeable. Stateless across launches (the next launch tries the primary
    /// first again).
    private static let catalogLog = Logger(subsystem: "ai.reyes.thetin", category: "Catalog")

    private func ensureLatestWithFailover(
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> CatalogUpdateOutcome {
        let outcome = try await updateFromPrimaryOrFallback(onProgress: onProgress)
        if case .installed(let version) = outcome {
            // Wishlist price alerts: diff + snapshot after EVERY successful install — this
            // wrapper is the single funnel for foreground start, tier switch, background
            // refresh, and the BG tasks (spec: "hook into the updater's completion").
            await priceAlerts.runAfterInstall(version: version, dbPath: paths.databaseURL.path)
        }
        return outcome
    }

    private func updateFromPrimaryOrFallback(
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> CatalogUpdateOutcome {
        let primaryKind = String(describing: type(of: remote))
        do {
            let outcome = try await CatalogUpdater(remote: remote, paths: paths)
                .ensureLatest(onProgress: onProgress)
            // A successful primary fetch means its manifest (and, for self-host, the App Attest
            // session token) round-tripped — this line is how we confirm the NAS path is live.
            activeSource = remote is SelfHostedCatalogRemote ? .selfHosted : .firebase
            Self.catalogLog.notice("catalog: primary \(primaryKind, privacy: .public) served \(String(describing: outcome), privacy: .public)")
            return outcome
        } catch {
            guard let fallbackRemote else {
                Self.catalogLog.error("catalog: primary \(primaryKind, privacy: .public) failed, no fallback — \(String(describing: error), privacy: .public)")
                throw error
            }
            Self.catalogLog.notice("catalog: primary \(primaryKind, privacy: .public) failed (\(String(describing: error), privacy: .public)) — falling back to Firebase")
            let outcome = try await CatalogUpdater(remote: fallbackRemote, paths: paths)
                .ensureLatest(onProgress: onProgress)
            activeSource = .firebase
            Self.catalogLog.notice("catalog: fallback Firebase served \(String(describing: outcome), privacy: .public)")
            return outcome
        }
    }

    /// Display-only funding progress, recomputed from the last-known `catalogState` (survives
    /// offline). Drives the support bar + Settings section; never gates anything.
    var funding: FundingDisplay {
        FundingModel.display(from: catalogState?.funding)
    }

    func start() async {
        phase = .launching

        // 1. Identity (best-effort: catalog features never depend on it).
        var repository: CollectionRepository = InMemoryCollectionRepository()
        var wantsRepository: WantsRepository = InMemoryWantsRepository()
        var uid = "local"
        if !skipFirebase {
            if FirebaseBootstrap.configure() == nil {
                phase = .failed("App misconfigured: missing Firebase configuration.")
                return
            }
            // Owned collection AND wishlist are on-device (local-only decision) and
            // auth-independent — routing or hearting a card never leaves the device. Auth below is
            // only for catalog/fingerprint downloads.
            // Created once (uid never keys these paths — collection.json is fixed, and
            // LocalWantsRepository ignores uid) and reused across retry() re-entries, so
            // BackupService keeps observing the same instances instead of going stale.
            if repositoryInstance == nil {
                repositoryInstance = makeRepository(uid)
                wantsRepositoryInstance = LocalWantsRepository()
            }
            repository = repositoryInstance!
            wantsRepository = wantsRepositoryInstance!
            if let authUid = try? await AuthService.ensureSignedIn() {
                uid = authUid
            }
            // iCloud backup rides the local repositories (subscribe → debounce → snapshot).
            // Created once — retry() re-enters start(). The restore offer runs in the
            // background; acceptance re-checks emptiness, so racing a first scan is safe.
            if backup == nil {
                let backupService = BackupService(collection: repository,
                                                  wants: wantsRepository, uid: uid)
                backupService.start()
                self.backup = backupService
                Task { await backupService.offerRestoreIfEligible() }
            }
        }

        // 2. Catalog: offline-first — an installed catalog always wins over the network.
        let updater = self.updater
        if updater.installedState() != nil,
           FileManager.default.fileExists(atPath: paths.databaseURL.path) {
            do {
                try openStore(repository: repository, wantsRepository: wantsRepository, uid: uid)
                phase = .ready
                Task { await self.backgroundRefresh() }
                return
            } catch {
                // corrupt local file — fall through to re-download
            }
        }

        phase = .downloadingCatalog
        do {
            _ = try await ensureLatestWithFailover()
            try openStore(repository: repository, wantsRepository: wantsRepository, uid: uid)
            phase = .ready
            Task { await self.backgroundRefresh() }
        } catch {
            phase = .failed("Couldn't download the card catalog. Check your connection and retry.")
        }
    }

    func retry() async { await start() }

    /// User picked a different data tier in Settings. Persist it, rebuild the NAS remote so it
    /// fetches the new tier, re-download immediately, and reopen the live store on the new bytes.
    func setTier(_ tier: CatalogTier) async {
        guard tier.rawValue != AppConfig.catalogTier else { return }
        AppConfig.catalogTier = tier.rawValue
        currentTier = tier.rawValue
        if let fresh = Self.selfHostedRemote() { remote = fresh }
        tierChange = .downloading
        do {
            _ = try await ensureLatestWithFailover()
            reopenStore() // sets catalogState; the swap poisoned the old handle (see backgroundRefresh)
            // The Firebase fallback only serves casual — a "successful" update there can install a
            // different tier than the one just picked. Say so instead of claiming success.
            if let installed = catalogState?.tier, installed != tier.rawValue {
                let name = CatalogTier(rawValue: installed)?.title ?? installed
                tierChange = .failed("\(tier.title) isn't available from the backup source — showing \(name) data for now.")
            } else {
                tierChange = .done
            }
        } catch {
            tierChange = .failed("Couldn't switch tier. Check your connection and try again.")
        }
    }

    private func openStore(repository: CollectionRepository, wantsRepository: WantsRepository, uid: String) throws {
        try? store?.close()
        let store = try CatalogStore(path: paths.databaseURL.path)
        self.store = store
        self.catalogState = updater.installedState()
        let collection = CollectionModel(repository: repository, store: store)
        collection.widgetWriter = WidgetSnapshotWriter()
        self.collection = collection
        Task { await collection.start() }
        let wants = WantsModel(repo: wantsRepository, uid: uid)
        wants.onWriteError = { [weak collection] message in
            collection?.writeError = .init(message: message)
        }
        self.wants = wants
    }

    /// Reopen the live store on the just-installed artifact. Required after any install that
    /// happens while a store is open: the swap deletes the open connection's WAL sidecars, which
    /// poisons every subsequent read. IN PLACE on the same CatalogStore instance — views and
    /// models (DiscoverModel, SearchModel…) capture it at creation and are never rebuilt
    /// mid-session, so a replacement instance leaves them querying a closed handle.
    private func reopenStore() {
        try? store?.reopen()
        catalogState = updater.installedState()
        collection?.catalogDidChange()
    }

    /// Non-nil while a catalog artifact is actually downloading (never during the cheap manifest
    /// check) — drives the "Updating card data…" toast. 0…1, monotonic within one download.
    private(set) var catalogDownloadProgress: Double?
    /// When the last quiet refresh ran, so foregrounding doesn't hammer the manifest endpoint.
    private(set) var lastRefreshCheck: Date?

    /// Foreground catch-up: the daily catalog usually lands while the app sits suspended, and
    /// BGTaskScheduler fires at iOS's whim — so scenePhase `.active` re-runs the quiet refresh,
    /// throttled to once an hour.
    func refreshIfStale() async {
        guard phase == .ready else { return }
        if let last = lastRefreshCheck, now().timeIntervalSince(last) < 3600 { return }
        await backgroundRefresh()
    }

    /// New catalog versions and daily price deltas, applied quietly behind a ready UI.
    private func backgroundRefresh() async {
        guard store != nil else { return }
        lastRefreshCheck = now()
        defer { catalogDownloadProgress = nil }
        // Whole-percent granularity (caps SwiftUI invalidations) + monotonic (progress hops to
        // the main actor via unordered Tasks — a late 61% must not undo 62%).
        let onProgress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            let current = self.catalogDownloadProgress ?? -0.01
            if Int(fraction * 100) > Int(current * 100) { self.catalogDownloadProgress = fraction }
        }
        if let outcome = try? await ensureLatestWithFailover(onProgress: onProgress),
           case .installed = outcome {
            // The swap invalidated the open store's WAL connection — reopen on the new artifact
            // (sets catalogState) so this session serves data instead of a dead handle.
            reopenStore()
        }
        guard let store else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let today = formatter.string(from: Date())
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86_400))
        // Price deltas are a Firebase-only resource (the NAS publishes none) and best-effort.
        let priceUpdater = CatalogUpdater(remote: fallbackRemote ?? remote, paths: paths)
        await priceUpdater.refreshPrices(store: store, dates: [yesterday, today])
        catalogState = updater.installedState()
    }

    // MARK: Background tasks (BGTaskScheduler entry points — see BackgroundRefresh.swift)

    /// Cheap manifest check for the BGAppRefreshTask: is there a newer catalog (or a pending
    /// tier switch) to download? Primary source only — the Firebase fallback exists for
    /// downloads, not polling. Any fetch failure just means "not now".
    func hasNewerCatalog() async -> Bool {
        guard let manifest = try? await remote.fetchManifest() else { return false }
        guard let state = updater.installedState() else { return true }
        return manifest.version > state.version || manifest.tier != state.tier
    }

    /// BGProcessingTask entry point: the normal tiered download + install, which fires the
    /// price-alerts diff via ensureLatestWithFailover. When a live store is open (task fired
    /// while suspended rather than background-launched), reopen it — the install swap deletes
    /// the open connection's WAL sidecars (see reopenStore).
    func backgroundCatalogUpdate() async -> Bool {
        guard let outcome = try? await ensureLatestWithFailover() else { return false }
        if case .installed = outcome { reopenStore() }
        return true
    }
}
