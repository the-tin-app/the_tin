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
    // Lazy on purpose: the Firebase-backed fallback calls `Storage.storage()`, which traps
    // unless FirebaseApp is fully configured — only construct it when failover actually fires.
    private let fallbackUpdater: () -> FingerprintUpdater?
    private let paths: FingerprintPaths
    private let catalogStore: CatalogStore
    private let makeStore: (String) throws -> FingerprintStore
    private let makeCodebook: () throws -> Codebook
    private var downloadTask: Task<Void, Never>?

    init(updater: FingerprintUpdater,
         fallbackUpdater: @autoclosure @escaping () -> FingerprintUpdater? = nil,
         paths: FingerprintPaths, catalogStore: CatalogStore,
         makeStore: @escaping (String) throws -> FingerprintStore,
         makeCodebook: @escaping () throws -> Codebook) {
        self.updater = updater; self.fallbackUpdater = fallbackUpdater
        self.paths = paths; self.catalogStore = catalogStore
        self.makeStore = makeStore; self.makeCodebook = makeCodebook
    }

    /// Convenience wiring used by the app (tests inject their own doubles). Self-hosted pack
    /// download (App Attest) when a self-host URL is configured — the pack is served alongside
    /// the catalog under `/fingerprint/`, with the Firebase Storage SDK as the whole-operation
    /// fallback. When self-host is unconfigured, Firebase is the primary and only source.
    /// Mirrors `AppModel.makeDefault()`.
    static func live(catalogStore: CatalogStore) -> ScannerPackModel {
        ScannerPackModel(
            updater: FingerprintUpdater(remote: liveRemote(), paths: .default()),
            fallbackUpdater: AppConfig.selfHostBaseURL == nil ? nil
                : FingerprintUpdater(remote: StorageFingerprintRemote(), paths: .default()),
            paths: .default(),
            catalogStore: catalogStore,
            makeStore: { try FingerprintStore(path: $0) },
            makeCodebook: { try Codebook.bundled() })
    }

    private static func liveRemote() -> FingerprintRemote {
        guard let url = AppConfig.selfHostBaseURL else { return StorageFingerprintRemote() }
        let session = AppAttestSessionProvider(baseURL: url, attestor: DeviceCheckAttestor(),
                                               http: URLSessionHTTPClient(), keys: KeychainStore())
        return SelfHostedFingerprintRemote(baseURL: url, session: session)
    }

    // MARK: Status

    var isDownloading: Bool { if case .downloading = phase { return true }; return false }

    var isPaused: Bool { if case .paused = phase { return true }; return false }

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
        buildScanDependencies()
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
    func startDownload() {
        guard !isDownloading else { return }
        phase = .downloading(progress ?? FingerprintDownloadProgress(bytesDone: 0,
                                                                     totalBytes: publishedBytes ?? 0))
        downloadTask = Task { [weak self] in
            await self?.runDownload()
        }
    }

    /// Awaits the in-flight transfer. Tests only; the UI observes `phase` instead.
    func waitForDownload() async { await downloadTask?.value }

    /// Parks the transfer. Cancellation loses at most the part in flight — every part already
    /// verified stays on disk, so resuming re-fetches one chunk, not the pack.
    func pause(_ reason: PauseReason = .user) {
        guard isDownloading else { return }
        downloadTask?.cancel()
        downloadTask = nil
        phase = .paused(progress ?? FingerprintDownloadProgress(bytesDone: 0, totalBytes: publishedBytes ?? 0),
                        reason)
    }

    /// Auto-pause when the path turns metered mid-download. Someone who starts on home Wi-Fi and
    /// walks out the door should not silently spend a few hundred MB of cellular data; the paused
    /// UI offers to carry on anyway.
    func networkChanged(isExpensive: Bool) {
        if isExpensive, isDownloading { pause(.cellular) }
    }

    private func runDownload() async {
        do {
            _ = try await ensureLatestWithFailover()
            updateAvailable = false
            installedVersion = updater.installedState()?.version
            installedBytes = updater.installedSizeBytes()
            buildScanDependencies()
            phase = (matcher != nil && index != nil) ? .ready : .unavailable("Scanner data unavailable.")
        } catch is CancellationError {
            // pause() already parked the phase; nothing to report.
        } catch let e as CatalogError where e == .incompatibleCodebook {
            phase = .unavailable("Scanner needs an app update.")
        } catch {
            // Bytes already verified stay on disk, so this is a resume point, not a restart.
            if let p = progress, p.bytesDone > 0 {
                phase = .paused(p, .user)
            } else {
                phase = .unavailable("Download failed. Check your connection and try again.")
            }
        }
    }

    /// Whole-operation failover mirroring `AppModel.updateFromPrimaryOrFallback`: the update runs
    /// entirely against the primary (manifest + pack together); on ANY failure the whole update
    /// retries against the fallback. Never mixes the two sources' manifests/artifacts. Covers a
    /// dev-mode self-hosted server rejecting production App Attest.
    private func ensureLatestWithFailover() async throws -> FingerprintUpdateOutcome {
        do { return try await updater.ensureLatest(onProgress: progressSink()) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard let fallback = fallbackUpdater() else { throw error }
            return try await fallback.ensureLatest(onProgress: progressSink())
        }
    }

    /// Monotonic sink — byte counts can hop to the main actor out of order, and a resumed
    /// transfer must never appear to go backwards.
    private func progressSink() -> @MainActor @Sendable (FingerprintDownloadProgress) -> Void {
        { [weak self] update in
            guard let self, self.isDownloading else { return }
            if let current = self.progress, update.bytesDone < current.bytesDone { return }
            self.phase = .downloading(update)
        }
    }

    // MARK: Deletion

    /// Reclaims the pack's disk space. The collection is untouched — only camera scanning stops
    /// working, until the pack is downloaded again.
    func deletePack() {
        pause()
        downloadTask?.cancel()
        downloadTask = nil
        // Drop the live handle first: the Matcher holds the sqlite open, and deleting the file
        // out from under it would leave the scanner reading a unlinked inode.
        matcher = nil
        index = nil
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
    private func buildScanDependencies() {
        do {
            let store = try makeStore(paths.databaseURL.path)
            let codebook = try makeCodebook()
            matcher = try Matcher(store: store, codebook: codebook)
            index = try CandidateIndex(store: catalogStore)
        } catch {
            matcher = nil
            index = nil
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
}

extension FingerprintDownloadProgress {
    /// "180 MB of 520 MB" — the honest phrasing for a transfer someone may leave and come back to.
    var byteSummary: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(bytesDone), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "\(done) of \(total)"
    }
}
