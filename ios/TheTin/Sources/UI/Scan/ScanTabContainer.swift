import SwiftUI
import Observation

/// Gates the Scan tab on pack availability: `checking` the installed-pack file →
/// `needsDownload` (first-open Wi-Fi prompt) → `downloading` → `ready` (Matcher built
/// from the installed pack + bundled codebook) or `unavailable` on a hard failure
/// (incompatible codebook, checksum mismatch, network error, ...).
@MainActor @Observable
final class ScanGateModel {
    enum State: Equatable { case checking, needsDownload, downloading, ready, unavailable(String) }
    private(set) var state: State = .checking
    /// Whole-percent download progress for the `.downloading` UI. Monotonic within one
    /// attempt (late main-actor hops can land out of order); reset when the failover
    /// restarts the download from a different source.
    private(set) var downloadPercent = 0
    private(set) var matcher: Matcher?
    private(set) var index: CandidateIndex?

    private let updater: FingerprintUpdater
    // Lazy on purpose: the Firebase-backed fallback calls `Storage.storage()`, which traps
    // unless FirebaseApp is fully configured — only construct it when failover actually fires.
    private let fallbackUpdater: () -> FingerprintUpdater?
    private let paths: FingerprintPaths
    private let catalogStore: CatalogStore
    private let makeStore: (String) throws -> FingerprintStore
    private let makeCodebook: () throws -> Codebook

    init(updater: FingerprintUpdater,
         fallbackUpdater: @autoclosure @escaping () -> FingerprintUpdater? = nil,
         paths: FingerprintPaths, catalogStore: CatalogStore,
         makeStore: @escaping (String) throws -> FingerprintStore,
         makeCodebook: @escaping () throws -> Codebook) {
        self.updater = updater; self.fallbackUpdater = fallbackUpdater
        self.paths = paths; self.catalogStore = catalogStore
        self.makeStore = makeStore; self.makeCodebook = makeCodebook
    }

    func check() async {
        let hasLocal = FileManager.default.fileExists(atPath: paths.databaseURL.path)
        // Consult the manifest so a stale installed pack (e.g. the v1 nf=300 → v2 nf=1000
        // fp_version bump) is upgraded instead of silently loading the old pack. Degrade to
        // the local pack when the manifest is unreachable so the scanner still works offline.
        let current: Bool
        do { current = try await updater.isCurrent() }
        catch { current = hasLocal }
        guard current, hasLocal else {
            state = .needsDownload
            return
        }
        buildScanDependencies()
        state = (matcher != nil && index != nil) ? .ready : .unavailable("Scanner data unavailable.")
    }

    /// Whole-operation failover mirroring `AppModel.updateFromPrimaryOrFallback`: the update
    /// runs entirely against the primary (manifest + pack together); on ANY failure the whole
    /// update retries against the fallback. Never mixes the two sources' manifests/artifacts.
    /// Covers a dev-mode self-hosted server rejecting production App Attest.
    private func ensureLatestWithFailover() async throws -> FingerprintUpdateOutcome {
        do { return try await updater.ensureLatest(onProgress: progressSink()) }
        catch {
            guard let fallback = fallbackUpdater() else { throw error }
            downloadPercent = 0   // fresh download from the fallback source
            return try await fallback.ensureLatest(onProgress: progressSink())
        }
    }

    /// Monotonic whole-percent sink (fractions can hop to the main actor out of order).
    private func progressSink() -> @MainActor @Sendable (Double) -> Void {
        { [weak self] fraction in
            guard let self else { return }
            let pct = Int(fraction * 100)
            if pct > self.downloadPercent { self.downloadPercent = pct }
        }
    }

    func download() async {
        state = .downloading
        downloadPercent = 0
        do {
            _ = try await ensureLatestWithFailover()
            buildScanDependencies()
            state = (matcher != nil && index != nil) ? .ready : .unavailable("Scanner data unavailable.")
        } catch let e as CatalogError where e == .incompatibleCodebook {
            state = .unavailable("Scanner needs an app update.")
        } catch {
            state = .unavailable("Download failed. Check Wi-Fi and try again.")
        }
    }

    /// Resets to `.checking`, which re-runs `check()` via the view's `.task`. Lets the
    /// `.unavailable` view offer a way back instead of stranding the user.
    func retry() {
        state = .checking
    }

    /// Surfaces an out-of-band failure (e.g. collection setup) as `.unavailable` instead
    /// of leaving the caller to silently proceed with a bogus fallback.
    func fail(_ message: String) {
        state = .unavailable(message)
    }

    /// Builds the Matcher and CandidateIndex the live scanner needs. Never throws/crashes:
    /// any failure (corrupt/unopenable pack, bad codebook, catalog read failure) leaves
    /// both nil so the caller can degrade to `.unavailable` instead of crashing or
    /// stranding the UI in a permanently-loading `.ready` state.
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
}

/// Hosts the live scanner: renders the gate states, and once the pack is installed and
/// the Matcher builds, enters `ScanView` backed by a persisted staging tray.
struct ScanTabContainer: View {
    let store: CatalogStore
    let collection: CollectionModel
    @State private var gate: ScanGateModel
    @State private var source = AVCaptureFrameSource()
    @State private var staging = ScanStagingStore.persisted()

    init(store: CatalogStore, collection: CollectionModel) {
        self.store = store
        self.collection = collection
        _gate = State(wrappedValue: ScanGateModel(
            updater: FingerprintUpdater(remote: Self.fingerprintRemote(), paths: .default()),
            fallbackUpdater: AppConfig.selfHostBaseURL == nil ? nil
                : FingerprintUpdater(remote: StorageFingerprintRemote(), paths: .default()),
            paths: .default(),
            catalogStore: store,
            makeStore: { try FingerprintStore(path: $0) },
            makeCodebook: { try Codebook.bundled() }))
    }

    /// Self-hosted pack download (App Attest) when a self-host URL is configured — the scanner pack
    /// is served alongside the catalog under `/fingerprint/`, with the Firebase Storage SDK as the
    /// whole-operation fallback (see `ScanGateModel.ensureLatestWithFailover`). When self-host is
    /// unconfigured, Firebase is the primary and only source. Mirrors `AppModel.makeDefault()`.
    private static func fingerprintRemote() -> FingerprintRemote {
        guard let url = AppConfig.selfHostBaseURL else { return StorageFingerprintRemote() }
        let session = AppAttestSessionProvider(baseURL: url, attestor: DeviceCheckAttestor(),
                                               http: URLSessionHTTPClient(), keys: KeychainStore())
        return SelfHostedFingerprintRemote(baseURL: url, session: session)
    }

    var body: some View {
        content
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var content: some View {
        switch gate.state {
        case .checking:
            TinLoadingView(label: "Preparing scanner…").task { await gate.check() }
        case .needsDownload:
            VStack(spacing: 12) {
                Image(systemName: "camera.viewfinder").font(.largeTitle)
                Text("Scanner needs a one-time download").font(.headline)
                Text("~500 MB over Wi-Fi. After this, scanning works offline.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Download") { Task { await gate.download() } }.buttonStyle(.borderedProminent)
            }.padding()
        case .downloading:
            VStack(spacing: 12) {
                ProgressView(value: Double(gate.downloadPercent), total: 100)
                    .frame(maxWidth: 240)
                Text("Downloading scanner data… \(gate.downloadPercent)%")
                    .font(.footnote).foregroundStyle(.secondary)
                    .monospacedDigit()
            }.padding()
        case .unavailable(let msg):
            VStack(spacing: 12) {
                ContentUnavailableView("Scanner unavailable", systemImage: "camera.metering.unknown", description: Text(msg))
                Button("Retry") { gate.retry() }.buttonStyle(.bordered)
            }
        case .ready:
            if let matcher = gate.matcher, let index = gate.index {
                ScanView(model: makeScanModel(matcher, index: index), staging: staging,
                         collection: collection, store: store, source: source)
            } else {
                TinLoadingView()
            }
        }
    }

    private func makeScanModel(_ matcher: Matcher, index: CandidateIndex) -> ScanModel {
        ScanModel(matcher: matcher, detector: CardDetector(),
                  textGate: TextGate(index: index), narrowing: index, staging: staging, store: store)
    }
}
