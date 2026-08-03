import Foundation
import Observation

/// Owns the scanner fingerprint pack for the whole app: what's installed, what's downloading,
/// and the `Matcher`/`CandidateIndex` the live scanner runs on.
///
/// Hoisted above the Scan tab on purpose. The pack used to be downloadable from exactly one
/// screen, which meant a new user met a several-hundred-MB wall as the first thing the headline
/// feature did, and a download could only be watched by staying on that screen. One shared owner
/// lets Settings, the first-run prompt and the Scan tab all start, watch, pause and resume the
/// same transfer.
@MainActor @Observable
final class ScannerPackModel {
    enum PauseReason: Equatable {
        case user
        /// Auto-paused because the path went cellular mid-download — see `networkChanged`.
        case cellular
    }

    enum Phase: Equatable {
        case checking
        /// No usable pack, and nothing downloaded yet.
        case notInstalled
        case downloading(FingerprintDownloadProgress)
        /// Bytes are on disk and the transfer can pick up where it stopped.
        case paused(FingerprintDownloadProgress, PauseReason)
        case ready
        case unavailable(String)

        var pauseReason: PauseReason? {
            if case .paused(_, let reason) = self { return reason }
            return nil
        }
    }

    private(set) var phase: Phase = .checking
    private(set) var matcher: Matcher?
    private(set) var index: CandidateIndex?
    /// Version of the pack currently installed, nil when none is.
    private(set) var installedVersion: Int?
    /// On-disk size of the installed pack — what Settings offers to reclaim.
    private(set) var installedBytes: Int?
    /// Download size advertised by the server, so no screen has to hardcode "~500 MB" (the
    /// hardcoded copy was 60% low by the time the v2 pack shipped).
    private(set) var publishedBytes: Int?
    /// A newer pack exists but the installed one still works — offered, never forced.
    private(set) var updateAvailable = false

    private let updater: FingerprintUpdater
    private let paths: FingerprintPaths
    private let catalogStore: CatalogStore
    private let makeStore: (String) throws -> FingerprintStore
    private let makeCodebook: () throws -> Codebook
    /// Consulted directly rather than through a SwiftUI `onChange`: the auto-pause must not
    /// depend on a view being on screen or on observation timing.
    private let network: NetworkMonitor?
    /// Which installed version `matcher`/`index` were built against, so a re-check can skip the
    /// rebuild. nil means "nothing usable built".
    private var builtVersion: Int?
    /// In-flight dependency build, shared by concurrent callers — see `buildScanDependencies()`.
    private var buildTask: Task<(matcher: Matcher, index: CandidateIndex)?, Never>?
    /// Rate limiter for the progress figure — see `progressSink()`.
    private var lastProgressPaint = Date.distantPast
    /// Every byte count as reported, un-throttled. The *displayed* figure is rate-limited, but
    /// where the transfer actually got to is state, not decoration: parking or failing a
    /// download has to record the real position, or a drop just under the repaint threshold
    /// reads as "nothing downloaded" and restarts from zero.
    private var latestProgress: FingerprintDownloadProgress?
    private var downloadTask: Task<Void, Never>?
    private var networkWatch: Task<Void, Never>?
    /// Set when the user explicitly accepted a metered download ("Download now" / "Resume
    /// anyway"). Without it the watcher would park the very transfer they just approved.
    private var allowsExpensive = false

    init(updater: FingerprintUpdater,
         paths: FingerprintPaths, catalogStore: CatalogStore,
         makeStore: @escaping (String) throws -> FingerprintStore,
         makeCodebook: @escaping () throws -> Codebook,
         network: NetworkMonitor? = nil) {
        self.updater = updater
        self.paths = paths; self.catalogStore = catalogStore
        self.makeStore = makeStore; self.makeCodebook = makeCodebook
        self.network = network
    }

    /// Convenience wiring used by the app (tests inject their own doubles). The pack is served
    /// from the self-hosted NAS (App Attest, alongside the catalog under `/fingerprint/`), with
    /// the R2 backup (App Check) behind it — see `liveRemote()`.
    ///
    /// **This used to have no fallback at all, by decision (2026-07-24)** — the pack was never
    /// mirrored anywhere, so a fallback could only ever fail and turned a clear "download failed"
    /// into a doubled timeout. That reasoning was sound; what changed is that the pack now has a
    /// real backup (R2, zero egress — the exact fact that killed the original trade).
    static func live(catalogStore: CatalogStore, network: NetworkMonitor) -> ScannerPackModel {
        ScannerPackModel(
            updater: FingerprintUpdater(remote: liveRemote(), paths: .default()),
            paths: .default(),
            catalogStore: catalogStore,
            makeStore: { try FingerprintStore(path: $0) },
            makeCodebook: { try Codebook.bundled() },
            network: network)
    }

    /// ...serves the pack from the self-hosted NAS, with the R2 backup origin behind it.
    private static func liveRemote() -> FingerprintRemote {
        let backup = OriginFingerprintRemote(baseURL: AppConfig.backupBaseURL,
                                             authorize: Authorizers.appCheck())
        guard let url = AppConfig.selfHostBaseURL else { return backup }
        let session = AppAttestSessionProvider(baseURL: url, attestor: DeviceCheckAttestor(),
                                               http: URLSessionHTTPClient(), keys: KeychainStore())
        return FailoverFingerprintRemote(
            primary: OriginFingerprintRemote(baseURL: url, authorize: Authorizers.appAttest(session)),
            fallback: backup)
    }

    // MARK: Status

    var isDownloading: Bool { if case .downloading = phase { return true }; return false }

    /// Whether camera scanning can run *right now*, which is not the same question as `phase`.
    ///
    /// An update downloads into a separate incoming file and only swaps at the end, so the
    /// installed pack keeps serving the matcher for the whole transfer — the open sqlite handle
    /// survives the swap by reading the old inode, the same mechanic `deletePack()` guards
    /// against. The Scan tab used to switch on `phase` alone, so `.downloading` replaced a
    /// perfectly good live scanner with the first-install download wall for ~568 MB. That
    /// contradicted the entire reason `updateAvailable` exists.
    var isScannerUsable: Bool { matcher != nil && index != nil }

    var isPaused: Bool { if case .paused = phase { return true }; return false }

    /// Why the transfer is parked, nil when it isn't.
    var pauseReason: PauseReason? { phase.pauseReason }

    /// Progress of whatever transfer is in flight or parked, for the toast and Settings.
    var progress: FingerprintDownloadProgress? {
        switch phase {
        case .downloading(let p): return p
        case .paused(let p, _): return p
        default: return nil
        }
    }

    /// Resolves what to show *without* taking a working scanner away for a merely-old pack.
    ///
    /// Only an incompatible pack — different fpVersion or codebook, which would silently
    /// mismatch — sends an existing user back to the download wall. A newer `version` alone
    /// leaves the installed pack in service and just sets `updateAvailable`. When the manifest
    /// is unreachable the installed pack is trusted, so the scanner still works offline.
    func refresh() async {
        guard !isDownloading else { return }   // a live transfer already owns the phase

        let installed = updater.installedState()
        let hasFile = FileManager.default.fileExists(atPath: paths.databaseURL.path)
        installedVersion = hasFile ? installed?.version : nil
        installedBytes = hasFile ? updater.installedSizeBytes() : nil

        let gates = try? await updater.publishedGates()
        publishedBytes = gates?.sizeBytes ?? publishedBytes

        guard let installed, hasFile else {
            phase = pendingPartial(gates: gates).map { .paused($0, .user) } ?? .notInstalled
            return
        }

        if let gates {
            guard gates.fpVersion == installed.fpVersion,
                  gates.codebookHash == installed.codebookHash else {
                // Genuinely unusable against this app's codebook — re-download is the only path.
                phase = pendingPartial(gates: gates).map { .paused($0, .user) } ?? .notInstalled
                return
            }
            updateAvailable = gates.version > installed.version
        }
        await buildScanDependencies()
        phase = (matcher != nil && index != nil) ? .ready : .unavailable("Scanner data unavailable.")
    }

    /// Progress of a partial download that still belongs to what the server publishes. A partial
    /// for some other pack is dropped rather than shown as resumable.
    private func pendingPartial(gates: FingerprintPublishedGates?) -> FingerprintDownloadProgress? {
        guard let partial = updater.downloadState() else { return nil }
        if let gates, partial.version != gates.version || partial.fpVersion != gates.fpVersion
            || partial.codebookHash != gates.codebookHash {
            updater.discardPartialDownload()
            return nil
        }
        let done = partial.completedParts.count * partial.partSize
        return FingerprintDownloadProgress(bytesDone: min(done, partial.totalBytes),
                                           totalBytes: partial.totalBytes)
    }

    // MARK: Download control

    /// Starts or resumes the pack download. Safe to call from any screen; a second call while a
    /// transfer is running is ignored rather than racing a duplicate download.
    ///
    /// `allowingExpensive` records that the user accepted a metered download, so the cellular
    /// watcher leaves it alone.
    func startDownload(allowingExpensive: Bool = false) {
        guard !isDownloading else { return }
        // Assign, don't OR in: consent belongs to the transfer the user approved. Accumulating it
        // meant one "Download now" over cellular silenced the guard for every later download.
        allowsExpensive = allowingExpensive
        latestProgress = progress
        lastProgressPaint = .distantPast   // the first byte count of a transfer always paints
        phase = .downloading(progress ?? FingerprintDownloadProgress(bytesDone: 0,
                                                                     totalBytes: publishedBytes ?? 0))
        downloadTask = Task { [weak self] in
            await self?.runDownload()
        }
        startNetworkWatch()
    }

    /// Awaits the in-flight transfer. Tests only; the UI observes `phase` instead.
    func waitForDownload() async { await downloadTask?.value }

    /// Parks the transfer. Cancellation loses at most the part in flight — every part already
    /// verified stays on disk, so resuming re-fetches one chunk, not the pack.
    func pause(_ reason: PauseReason = .user) {
        guard isDownloading else { return }
        stopNetworkWatch()
        downloadTask?.cancel()
        downloadTask = nil
        phase = .paused(trueProgress ?? FingerprintDownloadProgress(bytesDone: 0, totalBytes: publishedBytes ?? 0),
                        reason)
    }

    /// Parks the transfer when the path turns metered. Someone who starts on home Wi-Fi and walks
    /// out the door should not silently spend a few hundred MB of cellular data; the paused UI
    /// offers to carry on anyway.
    ///
    /// Polled rather than pushed through SwiftUI: the first cut hung this off an `onChange` in the
    /// tab view and it never fired on device. A poll during an active download costs nothing and
    /// can't be defeated by which screen happens to be mounted.
    // ponytail: 1 s poll; if NetworkMonitor ever grows real subscribers, subscribe instead.
    private func startNetworkWatch() {
        guard network != nil, networkWatch == nil else { return }
        networkWatch = Task { [weak self] in
            while !Task.isCancelled {
                // Check first, sleep second: starting a download while already on a metered path
                // must park immediately, not a second into spending the data.
                guard let self, self.isDownloading else { return }
                if self.network?.isExpensive == true, !self.allowsExpensive {
                    self.pause(.cellular)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopNetworkWatch() {
        networkWatch?.cancel()
        networkWatch = nil
    }

    /// Direct entry point for the same rule, used by tests and by any caller that already knows
    /// the path turned metered.
    func networkChanged(isExpensive: Bool) {
        if isExpensive, isDownloading, !allowsExpensive { pause(.cellular) }
    }

    private func runDownload() async {
        defer { stopNetworkWatch() }
        do {
            _ = try await updater.ensureLatest(onProgress: progressSink())
            updateAvailable = false
            allowsExpensive = false      // a fresh transfer must ask again
            installedVersion = updater.installedState()?.version
            installedBytes = updater.installedSizeBytes()
            await buildScanDependencies()
            phase = (matcher != nil && index != nil) ? .ready : .unavailable("Scanner data unavailable.")
        } catch is CancellationError {
            // pause() already parked the phase; nothing to report.
        } catch let e as CatalogError where e == .incompatibleCodebook {
            phase = .unavailable("Scanner needs an app update.")
        } catch {
            // Bytes already verified stay on disk, so this is a resume point, not a restart.
            if let p = trueProgress, p.bytesDone > 0 {
                phase = .paused(p, .user)
            } else {
                phase = .unavailable("Download failed. Check your connection and try again.")
            }
        }
    }

    /// Monotonic sink — byte counts can hop to the main actor out of order, and a resumed
    /// transfer must never appear to go backwards.
    ///
    /// Also rate-limited. Progress is reported per network chunk now rather than per 50 MiB
    /// part, which fires many times a second: the figure churned far faster than it could be
    /// read. Repaint on a whole megabyte of movement and at most four times a second — and
    /// always on the final byte, so the bar never stops just short of full.
    private func progressSink() -> @MainActor @Sendable (FingerprintDownloadProgress) -> Void {
        { [weak self] update in
            guard let self, self.isDownloading else { return }
            guard let current = self.progress else { self.paint(update); return }
            if update.bytesDone < current.bytesDone { return }
            self.latestProgress = update
            if update.totalBytes > 0, update.bytesDone >= update.totalBytes {
                self.paint(update); return
            }
            guard update.bytesDone - current.bytesDone >= 1_000_000,
                  Date().timeIntervalSince(self.lastProgressPaint) >= 0.25 else { return }
            self.paint(update)
        }
    }

    private func paint(_ update: FingerprintDownloadProgress) {
        lastProgressPaint = Date()
        latestProgress = update
        phase = .downloading(update)
    }

    /// Where the transfer really got to — the un-throttled count when there is one, else
    /// whatever the phase last showed.
    private var trueProgress: FingerprintDownloadProgress? { latestProgress ?? progress }

    // MARK: Deletion

    /// Reclaims the pack's disk space. The collection is untouched — only camera scanning stops
    /// working, until the pack is downloaded again.
    func deletePack() {
        pause()
        stopNetworkWatch()
        downloadTask?.cancel()
        downloadTask = nil
        allowsExpensive = false
        // Drop the live handle first: the Matcher holds the sqlite open, and deleting the file
        // out from under it would leave the scanner reading a unlinked inode.
        matcher = nil
        index = nil
        builtVersion = nil
        updater.deleteInstalledPack()
        installedVersion = nil
        installedBytes = nil
        updateAvailable = false
        phase = .notInstalled
    }

    /// Throws away a parked partial without touching an installed pack.
    func discardPartialDownload() {
        guard !isDownloading else { return }
        updater.discardPartialDownload()
        phase = installedVersion == nil ? .notInstalled : .ready
    }

    // MARK: Matcher

    /// Builds the Matcher and CandidateIndex the live scanner needs. Never throws/crashes: any
    /// failure (corrupt/unopenable pack, bad codebook, catalog read failure) leaves both nil so
    /// the caller can degrade to `.unavailable` instead of crashing or stranding the UI in a
    /// permanently-loading `.ready` state.
    /// Runs OFF the main actor, and that is a correctness fix rather than a tuning one.
    /// `Matcher.init` reads every card id in the pack (23k rows) and `CandidateIndex.init` walks
    /// every set and every card in the catalog to build four dictionaries. Both used to run on
    /// the MainActor, so finishing a pack update froze the entire app for seconds at exactly the
    /// moment the user is waiting to tap Scan — the tap queued behind the build and the tab
    /// switch landed after it. Same detached-read shape as `CardDetailModel.load()`.
    ///
    /// Concurrent callers share one build: `refresh()` runs from the root task, the Scan tab and
    /// the Settings sheet, and a cold launch into Scan fires two of them at once — without the
    /// shared task that is two full catalog walks for one result.
    private func buildScanDependencies() async {
        // Already built against this exact pack. `refresh()` runs on every Settings visit and
        // every Scan tab appearance now, not once per cold launch, so a re-check that finds
        // nothing changed must not pay for any of the above.
        if matcher != nil, index != nil, builtVersion == installedVersion { return }

        let task = buildTask ?? {
            let (path, make, makeBook, catalog) =
                (paths.databaseURL.path, makeStore, makeCodebook, catalogStore)
            let t = Task.detached(priority: .userInitiated) {
                Self.buildDependencies(path: path, makeStore: make,
                                       makeCodebook: makeBook, catalog: catalog)
            }
            buildTask = t
            return t
        }()
        let built = await task.value
        buildTask = nil

        matcher = built?.matcher
        index = built?.index
        builtVersion = built == nil ? nil : installedVersion
    }

    /// Never throws: any failure (corrupt/unopenable pack, bad codebook, catalog read failure)
    /// returns nil so the caller degrades to `.unavailable` rather than crashing or stranding
    /// the UI in a permanently-loading `.ready`.
    nonisolated private static func buildDependencies(
        path: String,
        makeStore: (String) throws -> FingerprintStore,
        makeCodebook: () throws -> Codebook,
        catalog: CatalogStore
    ) -> (matcher: Matcher, index: CandidateIndex)? {
        do {
            let matcher = try Matcher(store: makeStore(path), codebook: makeCodebook())
            return (matcher, try CandidateIndex(store: catalog))
        } catch {
            return nil
        }
    }

    /// Surfaces an out-of-band failure (e.g. collection setup) as `.unavailable` instead of
    /// leaving the caller to silently proceed with a bogus fallback.
    func fail(_ message: String) {
        phase = .unavailable(message)
    }

    /// Resets to `.checking`, which re-runs `refresh()` via the view's `.task`. Lets the
    /// `.unavailable` view offer a way back instead of stranding the user.
    func retry() {
        phase = .checking
    }

    #if DEBUG
    /// DEBUG-only: rewinds the *recorded* installed version by one, leaving the ~568 MB pack file
    /// untouched. `refresh()` then computes `published > installed` and offers the update, so the
    /// whole update path can be rehearsed on device against a real published pack — without
    /// republishing the old one to the NAS. Not being able to do that is why v3→v4 shipped
    /// unnoticed. Never compiled into Release.
    ///
    /// Deliberately does NOT call `refresh()`: the reported symptom is that a running app never
    /// re-checks, and refreshing here would paper over exactly the behaviour under test.
    func debugRewindInstalledVersion() {
        guard var state = updater.installedState() else { return }
        state.version -= 1
        try? updater.saveState(state)
    }
    #endif
}

extension FingerprintDownloadProgress {
    /// "180 MB of 520 MB" — the honest phrasing for a transfer someone may leave and come back to.
    ///
    /// Whole megabytes on both sides, deliberately. `ByteCountFormatter` switches units and
    /// fraction digits as the number grows ("948 KB" → "1.2 MB" → "12.44 MB"), so the string
    /// changed *width* several times a second and the digits slid sideways under the eye — the
    /// count was unreadable on device even though every value it showed was correct.
    var byteSummary: String {
        "\(Self.wholeMB(bytesDone)) MB of \(Self.wholeMB(totalBytes)) MB"
    }

    /// Matches `ByteCountFormatter`'s `.file` style, which is decimal (1 MB = 10^6 B) on Apple
    /// platforms — so this agrees with the "568.6 MB" the setup screens quote.
    private static func wholeMB(_ bytes: Int) -> Int {
        max(0, Int((Double(bytes) / 1_000_000).rounded()))
    }
}
