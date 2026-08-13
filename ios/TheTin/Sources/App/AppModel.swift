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

    enum CatalogSource: String { case selfHosted, backup }
    enum TierChange: Equatable { case idle, downloading, done, failed(String) }

    private(set) var phase: Phase = .launching
    private(set) var store: CatalogStore?
    private(set) var collection: CollectionModel?
    private(set) var wants: WantsModel?
    /// The sets you're collecting. Created eagerly (it's a file read, no network) so every screen
    /// can ask; nil never happens in the app, only in catalog-only tests.
    private(set) var setGoals: SetGoalsModel? = SetGoalsModel()
    /// Explicit Discover feedback — thumbs-down and stated reasons. Created eagerly for the same
    /// reason as `setGoals`: it is a small file read with no network behind it.
    ///
    /// Deliberately its OWN file rather than a field in `wants.json`. A failed read here costs a
    /// handful of thumbs-downs; a failed `wants.json` decode silently emptied the whole wishlist and
    /// the next write persisted the emptiness.
    private(set) var discoverSignals: DiscoverSignalsModel? = DiscoverSignalsModel()
    private(set) var catalogState: CatalogState?
    /// Which remote served the most recent catalog operation (nil until the first update runs).
    private(set) var activeSource: CatalogSource?
    /// The user's selected tier, mirrored from `AppConfig.catalogTier` so the Settings picker's
    /// checkmark updates reactively after a switch.
    private(set) var currentTier: String = AppConfig.catalogTier
    private(set) var tierChange: TierChange = .idle
    /// Inbound card deep link (`https://thetinapp.com/c/<id>`). RootView watches the token and
    /// pushes `CardID(pendingCardId)` onto the Tin stack — same pattern as the wishlist route.
    private(set) var cardRouteToken = 0
    private(set) var pendingCardId: String?
    /// Set when the link was a printed label (`?v=1&p=…&c=…`); nil for a plain share link.
    private(set) var pendingCardHighlight: CardHighlight?
    /// The last universal link acted on, to collapse a double delivery (see `handleDeepLink`).
    /// Short enough that deliberately opening the same link twice still works — a second tap is
    /// seconds away, two deliveries of one tap are milliseconds apart.
    private var lastHandledLink: (url: String, at: Date)?
    static let duplicateLinkWindow: TimeInterval = 1
    /// The label print run in flight, if any. Lives HERE rather than on each screen for the same
    /// reason the write-failure alert does: the thing that asks for a label is often a sheet that
    /// dismisses itself (the entry form's "Save & print"), and a flow owned by a dismissing view
    /// dies with it. One owner also means the start position carries across prints, so a
    /// part-used sheet stays usable over a whole session instead of resetting to slot 1.
    var labelRequest: LabelPrintRequest?

    /// Print a label once the sheet the caller is dismissing has actually gone.
    ///
    /// `dismiss()` has no completion, and asking UIKit to present while another sheet is animating
    /// away is the case it drops on the floor. So this waits out the dismissal rather than hopping
    /// one turn — a main-actor hop returns long before the animation ends.
    // ponytail: a fixed wait, not an observed one. UIKit gives no "the sheet is gone" signal to
    // SwiftUI here; if this ever misfires, the upgrade is a UIViewControllerRepresentable that
    // reports `viewDidDisappear`, which is a lot of machinery for one button.
    func printLabelAfterDismiss(_ request: LabelPrintRequest) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))   // > the ~0.35 s sheet dismissal
            labelRequest = request
        }
    }

    /// Which pinned row a confirmation points at. These are the two rows under the dividers that
    /// a state change can send a card to.
    enum PinnedRoute: Equatable { case wishlist, trade }

    /// A short-lived "that worked — here's where it went" toast with one navigation action.
    ///
    /// Deliberately NOT `CollectionModel.UndoableDelete`. Undo restores data and the user is
    /// racing a clock, so its offer carries `expiresAt` and draws a countdown bar. This only
    /// points at a screen: missing it costs nothing, so there is no bar and no deadline to render
    /// honestly. Same model-owned expiry task though, and for the same reason — see
    /// `CollectionModel.offerUndo`: a `.task` on the view is cancelled when SwiftUI re-identifies
    /// the toast, which swallows its own CancellationError and clears the offer inside a frame.
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        /// "On your trade list" — what the toast says happened.
        let message: String
        /// Where "View" goes.
        let route: PinnedRoute
    }

    private(set) var confirmation: Confirmation?
    private var confirmationExpiry: Task<Void, Never>?

    /// How long a confirmation stays up. Shorter than the 6 s undo window: nothing is lost by
    /// missing this one.
    static let confirmationWindow: Duration = .seconds(5)

    /// Raise a confirmation, replacing any already standing.
    func confirm(_ message: String, route: PinnedRoute) {
        confirmationExpiry?.cancel()
        confirmation = Confirmation(message: message, route: route)
        confirmationExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationWindow)
            // A cancelled sleep means a NEWER confirmation superseded this one, or the user took
            // the action. Clearing here would wipe that newer one.
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
            self?.confirmationExpiry = nil
        }
    }

    /// Raise a confirmation from a view that is dismissing itself.
    ///
    /// Same 450 ms as `printLabelAfterDismiss`, for the same reason: `dismiss()` has no
    /// completion handler, and UIKit drops a presentation attempted while another is still
    /// animating away. A main-actor hop returns far too early.
    ///
    /// ponytail: fixed timer, not an observed signal. The honest upgrade is a
    /// `UIViewControllerRepresentable` reporting `viewDidDisappear`, same shortcut and same
    /// upgrade path as `printLabelAfterDismiss` (#151).
    ///
    /// ⚠️ **Do not trust 450 ms as a measured number.** #151's equivalent wait measured 2-3
    /// SECONDS end to end on device, because `reset()` and downstream re-warm dominated the
    /// timer itself. This toast is lighter (no reset, no re-warm), so 450 ms is the starting
    /// point, not the verified one — it must be checked on device, not on the simulator.
    func confirmAfterDismiss(_ message: String, route: PinnedRoute) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            confirm(message, route: route)
        }
    }

    func clearConfirmation() {
        confirmationExpiry?.cancel()
        confirmationExpiry = nil
        confirmation = nil
    }

    /// The confirmation's action: dismiss the toast and ask `MainTabView` to push the row.
    /// Token-based like every other programmatic push in this app (`consumeCardRoute`,
    /// `consumeTradeRoute`) — the tab's `NavigationPath` lives in the view, not here.
    private(set) var pendingPinnedRoute: PinnedRoute?
    private(set) var pinnedRouteToken = 0

    func openPinned(_ route: PinnedRoute) {
        clearConfirmation()
        pendingPinnedRoute = route
        pinnedRouteToken += 1
    }

    func openCard(id: String, highlight: CardHighlight? = nil) {
        // Recorded HERE so every route in is captured, not just the deep-link one. A trail with a
        // preceding "handleDeepLink" line came from a universal link; one without came from an
        // in-app scanner. That distinction is the whole question for the step-5 report and the
        // first trail could not answer it.
        DeepLinkDiag.record("openCard", "\(id) highlight=\(highlight != nil)")
        pendingCardId = id
        pendingCardHighlight = highlight
        cardRouteToken += 1
    }

    /// Where an App Intent ("Scan a card", "Search cards") asked the app to go. Same token
    /// pattern as the wishlist/card routes above, so a second invocation re-routes.
    enum IntentRoute: Equatable {
        case scan
        case search(String)
    }
    private(set) var intentRouteToken = 0
    private(set) var pendingIntentRoute: IntentRoute?

    func openIntentRoute(_ route: IntentRoute) {
        pendingIntentRoute = route
        intentRouteToken += 1
    }

    /// A CSV handed to us from Files / AirDrop / a share sheet, waiting to be imported.
    ///
    /// Set by `handleDeepLink`; Settings consumes it and clears it. Nil the rest of the time.
    var pendingImportURL: URL?
    /// Bumped with `pendingImportURL` so re-opening the SAME file twice still registers as a new
    /// request — a plain `onChange` on the URL wouldn't fire the second time.
    private(set) var importRouteToken = 0

    /// "Open Settings AND put the file picker up", for the empty tin's Import option.
    ///
    /// Distinct from `importRouteToken` above, which carries a URL somebody already chose. This one
    /// carries no file: the user has said they want to import and hasn't picked anything yet.
    /// Landing them at the top of a ten-section Settings list and hoping they scroll to Data is how
    /// the importer stayed invisible to the people who needed it most.
    ///
    /// ⚠️ **A flag consumed by the reader, NOT a monotonic token.** This shipped first as a token
    /// with a `consumedImportPickerToken` counter in `SettingsView`, copying `RootView`'s pattern —
    /// and that pattern does not transfer, because `RootView`'s `MainTabView` lives for the whole
    /// session while **Settings is a `.sheet`**: it is destroyed and rebuilt on every open, so its
    /// `@State` counter reset to 0 each time and `1 > 0` fired the file picker again on every
    /// visit, forever (reported on device 2026-08-12). The "have we handled this?" bit has to
    /// outlive the view that handles it, so it lives here and Settings clears it.
    var wantsImportPicker = false

    func requestImportPicker() { wantsImportPicker = true }

    /// Someone's shared trade list, opened in the app instead of in a browser — the cards they
    /// said they'll part with, ready to become the other column of a trade.
    ///
    /// Same token pattern as the card route, so opening the SAME link twice is two requests.
    private(set) var tradeRouteToken = 0
    private(set) var pendingTradeOffer: ShareList.Payload?

    func openTradeOffer(_ payload: ShareList.Payload) {
        pendingTradeOffer = payload
        tradeRouteToken += 1
    }

    /// A universal link the app owns but has nothing to do with, to be handed back to the browser.
    ///
    /// The open itself belongs to the view layer — this model deliberately imports no UIKit, so
    /// the decision stays testable without a running app.
    private(set) var externalURLToken = 0
    private(set) var pendingExternalURL: URL?

    func openInBrowser(_ url: URL) {
        pendingExternalURL = url
        externalURLToken += 1
    }

    /// Parse a universal link. `/c/<id>` opens a card and `/l?d=…` opens a shared trade list;
    /// anything else is ignored so the web pages (home/privacy/support) keep opening in the
    /// browser.
    ///
    /// Also the entry point for FILES opened in The Tin. `CFBundleDocumentTypes` declares CSV, and
    /// a file URL has no `/c/<id>` shape — without this branch it would fall through the guard
    /// below and the app would launch and sit there, which is a worse experience than never
    /// offering "Open in The Tin" at all.
    func handleDeepLink(_ url: URL) {
        // DEBUG-only breadcrumb for the "scanning a label just launches the app" report. Written to
        // UserDefaults rather than logged because `log stream` can't attach to a device on this
        // macOS, while `devicectl device copy from … Library/Preferences` can — see CLAUDE.md.
        // Two hypotheses were argued into and both were wrong; this records what actually happens.
        DeepLinkDiag.record("handleDeepLink", url.absoluteString)
        // ⚠️ The app now listens on TWO doors — `onOpenURL` and `onContinueUserActivity` — because
        // universal links don't reliably come through the first. Both can fire for the SAME link,
        // and without this the token would bump twice and `consumeCardRoute` would push the card
        // twice, leaving a duplicate screen on the stack to back out of.
        if let last = lastHandledLink, last.url == url.absoluteString,
           now().timeIntervalSince(last.at) < Self.duplicateLinkWindow {
            DeepLinkDiag.record("ignored", "same link delivered twice")
            return
        }
        lastHandledLink = (url.absoluteString, now())
        if url.isFileURL {
            pendingImportURL = url
            importRouteToken += 1
            return
        }
        let parts = url.pathComponents   // e.g. ["/", "c", "base1-4"]
        if parts.count >= 2, parts[1] == "l" {
            // Only a TRADE payload opens a trade. A `.want` link is what somebody is looking FOR,
            // and seeding it as "what they'll give you" would invert the whole screen.
            //
            // ⚠️ Refusing it is NOT enough, and the comment here used to claim it was: "it keeps
            // falling through to the web page." It does not. The association file claims `/l`
            // wholesale — it cannot see the payload, which is gzipped inside `d` — so iOS opens
            // the app for a want link too, and a bare `return` leaves the user staring at
            // whatever screen they were on. Found on device 2026-08-01, one day after the
            // association file went live; before that the link opened Safari and worked.
            //
            // So a want link is handed BACK to the browser explicitly. The web page renders it
            // properly and that remains the right destination — it just has to be asked for now.
            guard let d = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "d" })?.value,
                  let payload = try? ShareList.decode(d) else { return }
            if payload.k == .trade {
                openTradeOffer(payload)
            } else {
                openInBrowser(url)
            }
            return
        }
        guard parts.count >= 3, parts[1] == "c", !parts[2].isEmpty else { return }
        // A printed label is this same link with `?v=1&p=…&c=…&e=…` on it, so one parser reads
        // both and the two can't drift — `LabelPayload` owns the version rules, including
        // "an unknown `v` opens the card and drops the rest".
        //
        // The `parts[2]` fallback deliberately keeps this branch host-agnostic, which it has
        // always been: `LabelPayload.parse` requires thetinapp.com because a label URL is a
        // printed contract, and tightening the deep-link handler to match is a behaviour change
        // this feature has no business making.
        let payload = LabelPayload.parse(url)
        let id = payload?.cardId ?? parts[2]
        openCard(id: id,
                 highlight: payload.flatMap { CardHighlight(printing: $0.printing,
                                                            condition: $0.condition) })
    }
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
    private var fallbackRemote: CatalogRemote?
    /// Which source `remote` actually is — can't be recovered by sniffing its type any more,
    /// since the self-hosted and backup remotes are both `OriginCatalogRemote` now.
    private let primarySource: CatalogSource
    private let paths: CatalogPaths
    private let makeRepository: (String) -> CollectionRepository
    private let skipFirebase: Bool // unit tests exercise catalog flow without Firebase
    private let now: () -> Date // injectable clock for deterministic funding tests
    private var updater: CatalogUpdater { CatalogUpdater(remote: remote, paths: paths) }

    /// The self-hosted NAS remote (App Attest identity), or nil when no self-host URL is configured.
    nonisolated static func selfHostedRemote() -> OriginCatalogRemote? {
        guard let url = AppConfig.selfHostBaseURL else { return nil }
        let session = AppAttestSessionProvider(baseURL: url, attestor: DeviceCheckAttestor(),
                                               http: URLSessionHTTPClient(), keys: KeychainStore())
        return OriginCatalogRemote(baseURL: url, authorize: Authorizers.appAttest(session),
                                   http: URLSessionHTTPClient())
    }

    /// The R2 backup origin (App Check identity) — same contract, independent auth chain.
    nonisolated static func backupRemote() -> OriginCatalogRemote {
        OriginCatalogRemote(baseURL: AppConfig.backupBaseURL, authorize: Authorizers.appCheck(),
                            http: URLSessionHTTPClient())
    }

    /// Production wiring: NAS primary (if configured) with R2 as the operation-level fallback.
    /// Failover is atomic per operation — a catalog update runs entirely against one origin
    /// (manifest + artifact together), never mixing two origins' version-specific artifact paths.
    /// Exactly TWO sources, deliberately: a third is how that invariant gets broken.
    @MainActor static func makeDefault(skipFirebase: Bool) -> AppModel {
        let backup = backupRemote()
        if let selfHosted = selfHostedRemote() {
            return AppModel(remote: selfHosted, fallback: backup,
                            primarySource: .selfHosted, skipFirebase: skipFirebase)
        }
        return AppModel(remote: backup, primarySource: .backup, skipFirebase: skipFirebase)
    }

    init(remote: CatalogRemote,
         fallback: CatalogRemote? = nil,
         primarySource: CatalogSource,
         paths: CatalogPaths = .default(),
         makeRepository: @escaping (String) -> CollectionRepository = { _ in LocalCollectionRepository() },
         skipFirebase: Bool = false,
         now: @escaping () -> Date = { Date() }) {
        self.remote = remote
        self.fallbackRemote = fallback
        self.primarySource = primarySource
        self.paths = paths
        self.makeRepository = makeRepository
        self.skipFirebase = skipFirebase
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
        if case .installed = outcome {
            // The install swap deleted the open connection's WAL sidecars. Reopen HERE — in the
            // same funnel that installed — so no call path (foreground start, tier switch,
            // background refresh, BG tasks) can forget and serve a dead handle for the session.
            reopenStore()
        }
        return outcome
    }

    private func updateFromPrimaryOrFallback(
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> CatalogUpdateOutcome {
        let primaryName = primarySource == .selfHosted ? "self-hosted" : "backup"
        do {
            let outcome = try await CatalogUpdater(remote: remote, paths: paths)
                .ensureLatest(onProgress: onProgress)
            // A successful primary fetch means its manifest (and, for self-host, the App Attest
            // session token) round-tripped — this line is how we confirm the NAS path is live.
            activeSource = primarySource
            Self.catalogLog.notice("catalog: primary \(primaryName, privacy: .public) served \(String(describing: outcome), privacy: .public)")
            if case .installed = outcome { CatalogActivity.record("\(primaryName): \(describe(outcome))") }
            return outcome
        } catch {
            guard let fallbackRemote else {
                Self.catalogLog.error("catalog: primary \(primaryName, privacy: .public) failed, no fallback — \(String(describing: error), privacy: .public)")
                CatalogActivity.record("\(primaryName) failed (\(shortError(error))), no backup configured")
                throw error
            }
            Self.catalogLog.notice("catalog: primary \(primaryName, privacy: .public) failed (\(String(describing: error), privacy: .public)) — falling back to backup")
            do {
                let outcome = try await CatalogUpdater(remote: fallbackRemote, paths: paths)
                    .ensureLatest(onProgress: onProgress)
                activeSource = .backup
                Self.catalogLog.notice("catalog: fallback backup served \(String(describing: outcome), privacy: .public)")
                CatalogActivity.record("self-hosted failed (\(shortError(error))) → backup: \(describe(outcome))")
                return outcome
            } catch let fallbackError {
                CatalogActivity.record("self-hosted failed (\(shortError(error))) → backup failed (\(shortError(fallbackError)))")
                throw fallbackError
            }
        }
    }

    private func describe(_ outcome: CatalogUpdateOutcome) -> String {
        let tier = updater.installedState()?.tier.map { " \($0)" } ?? ""
        switch outcome {
        case .installed(let v): return "installed v\(v)\(tier)"
        case .alreadyCurrent(let v): return "already current, v\(v)\(tier)"
        }
    }

    private func shortError(_ error: Error) -> String {
        String(String(describing: error).prefix(80))
    }

    /// True when the installed catalog is a poorer tier than the one the user chose — e.g. an
    /// older install (or a legacy untiered manifest) bootstrapped before the current tier was
    /// picked. Drives the "backup card data" banner so missing history/grades read as a state,
    /// not a bug. The R2 backup carries all three tiers now, so this no longer fires just because
    /// the NAS was unreachable.
    var reducedData: Bool {
        guard let installed = CatalogTier(rawValue: catalogState?.tier ?? ""),
              let chosen = CatalogTier(rawValue: currentTier),
              let i = CatalogTier.allCases.firstIndex(of: installed),
              let c = CatalogTier.allCases.firstIndex(of: chosen) else { return false }
        return i < c
    }

    /// Display-only funding progress, recomputed from the last-known `catalogState` (survives
    /// offline). Drives the support bar + Settings section; never gates anything.
    var funding: FundingDisplay {
        FundingModel.display(from: catalogState?.funding)
    }

    /// Sponsors who asked to be listed, from the same cached state (so the screen still renders
    /// offline). Empty until the served manifest carries names — which is the honest day-one state.
    var supporters: [Supporter] {
        FundingModel.supporters(from: catalogState?.supporters)
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
                                                  wants: wantsRepository, setGoals: setGoals,
                                                  uid: uid)
                backupService.start()
                self.backup = backupService
                Task { await backupService.offerRestoreIfEligible() }
            }

            // Photos are keyed by entry id and nothing deletes them per-entry. One sweep per
            // launch covers entry deletion, a form cancelled after a capture, a CSV "Replace
            // collection" and a restore. The first emission of entriesStream is the current
            // state on subscribe (same one-shot read `currentCounts` uses).
            // The same sweep pulls down anything a restore's own pass didn't get. iCloud
            // materialises a file when it materialises it, and the restore fires once — without a
            // retry, a photo that was still in flight at that moment would never arrive at all.
            // Both halves skip what is already on disk, so this is cheap on every ordinary launch.
            Task { [repository] in
                var entries: [CollectionEntry] = []
                for await v in repository.entriesStream() {
                    entries = v
                    break
                }
                let ids = Set(entries.map(\.id))
                let needed = PhotoStore.needed(from: entries)
                let store = PhotoStore.live()
                await Task.detached(priority: .background) {
                    store.prune(keeping: ids)
                    store.mirrorDown(needed: needed)
                }.value
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

    /// User picked a different data tier in Settings. Persist it, rebuild the NAS and R2 remotes
    /// so both fetch the new tier, re-download immediately, and reopen the live store on the new
    /// bytes. Rebuilding only `remote` and leaving `fallbackRemote` on the pre-switch tier would
    /// have the backup ask for the old tier, get a manifest stamped with it, fail the
    /// `unwantedTier` guard in `CatalogUpdater`, and report a false "isn't available from the
    /// backup source" — the backup carries every tier, it just never got asked for the right one.
    func setTier(_ tier: CatalogTier) async {
        guard tier.rawValue != AppConfig.catalogTier else { return }
        AppConfig.catalogTier = tier.rawValue
        currentTier = tier.rawValue
        // Both remotes bake in `tier` at construction (`OriginCatalogRemote.tier`), so a switch
        // has to rebuild whichever ones are real NAS/R2 remotes. `fallbackRemote` is gated on its
        // OWN current type rather than reusing the self-host guard verbatim: production always
        // pairs a real self-hosted `remote` with a real R2 `fallbackRemote` (`makeDefault` builds
        // both together), so this rebuilds exactly when the reviewer's fix requires — but a test
        // fake fallback (no tier concept, and no App Check identity to authorize with) is left
        // alone rather than replaced by a live R2 remote that can only fail in-process.
        if let fresh = Self.selfHostedRemote() { remote = fresh }
        if fallbackRemote is OriginCatalogRemote { fallbackRemote = Self.backupRemote() }
        tierChange = .downloading
        do {
            _ = try await ensureLatestWithFailover() // installs + reopens the live store in one funnel
            // The backup source could still install a different tier than the one just picked
            // (e.g. a stale manifest at the same version). Say so instead of claiming success.
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
        wants.onWishlistAdd = { [weak self] in
            self?.confirm("On your wishlist", route: .wishlist)
        }
        self.wants = wants
    }

    /// Reopen the live store on the just-installed artifact. Required after any install that
    /// happens while a store is open: the swap deletes the open connection's WAL sidecars, which
    /// poisons every subsequent read. IN PLACE on the same CatalogStore instance — views and
    /// models (DiscoverModel, SearchModel…) capture it at creation and are never rebuilt
    /// mid-session, so a replacement instance leaves them querying a closed handle.
    /// Called from the ensureLatestWithFailover funnel after every install; no-ops pre-openStore.
    private func reopenStore() {
        guard let store else { return }
        do {
            try store.reopen()
        } catch {
            // A failed reopen means every later read errors out as "empty data" — retry once,
            // then say so loudly instead of degrading silently.
            do { try store.reopen() } catch {
                Self.catalogLog.fault("catalog: reopen after install FAILED — \(String(describing: error), privacy: .public)")
                CatalogActivity.record("reopen after install FAILED (\(shortError(error))) — restart the app")
            }
        }
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

    /// New catalog versions, applied quietly behind a ready UI.
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
        _ = try? await ensureLatestWithFailover(onProgress: onProgress)
        catalogState = updater.installedState()
    }

    // MARK: Background tasks (BGTaskScheduler entry points — see BackgroundRefresh.swift)

    /// Cheap manifest check for the BGAppRefreshTask: is there a newer catalog (or a pending
    /// tier switch) to download? Primary source only — the backup fallback exists for
    /// downloads, not polling. Any fetch failure just means "not now".
    func hasNewerCatalog() async -> Bool {
        guard let manifest = try? await remote.fetchManifest() else { return false }
        guard let state = updater.installedState() else { return true }
        return manifest.version > state.version || manifest.tier != state.tier
    }

    /// BGProcessingTask entry point: the normal tiered download + install, which fires the
    /// price-alerts diff and (when a live store is open) the reopen via ensureLatestWithFailover.
    func backgroundCatalogUpdate() async -> Bool {
        (try? await ensureLatestWithFailover()) != nil
    }

    #if DEBUG
    /// DEBUG-only: wipe the installed catalog and run a normal `ensureLatestWithFailover`, so a
    /// disaster-recovery test can prove a fresh DOWNLOAD — not just the outage toggle's probe —
    /// is served entirely by the R2 backup. Reuses the same funnel `backgroundRefresh` does: the
    /// download toast (`catalogDownloadProgress`) and `CatalogActivity` log both behave exactly
    /// as they do for a real update, and `reopenStore()` (invoked inside the funnel on install)
    /// re-points the live store at the new file.
    ///
    /// Drops the live handle FIRST, same ordering as `ScannerPackModel.deletePack` /
    /// `FingerprintUpdater.deleteInstalledPack`: a `CatalogStore` holds the sqlite open, and
    /// deleting the file out from under it leaves readers on an unlinked inode. Only the catalog
    /// artifact and its state file are touched — the collection, wishlist, set goals, backups
    /// and scanner pack live under different paths.
    func debugDeleteCatalogAndRedownload() async {
        try? store?.close()
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: paths.databaseURL.path + suffix))
        }
        try? fm.removeItem(at: paths.stateURL)
        catalogState = nil
        activeSource = nil

        defer { catalogDownloadProgress = nil }
        let onProgress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            let current = self.catalogDownloadProgress ?? -0.01
            if Int(fraction * 100) > Int(current * 100) { self.catalogDownloadProgress = fraction }
        }
        _ = try? await ensureLatestWithFailover(onProgress: onProgress)
        catalogState = updater.installedState()
    }
    #endif
}
