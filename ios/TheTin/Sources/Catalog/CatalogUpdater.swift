import Foundation
import CryptoKit
import Gzip

struct CatalogPaths {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("catalog.sqlite") }
    var stateURL: URL { directory.appendingPathComponent("catalog-state.json") }

    static func `default`() -> CatalogPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CatalogPaths(directory: base.appendingPathComponent("Catalog", isDirectory: true))
    }
}

struct CatalogState: Codable, Equatable {
    var version: Int
    var priceAsOf: String?
    /// Community-funding snapshot, refreshed independently of `version` (see `ensureLatest`).
    var funding: FundingSnapshot? = nil
    /// Which tier is installed. Part of the install identity so a same-version tier switch still
    /// re-downloads. Nil for catalogs installed before tiering (compares equal to a nil manifest tier).
    var tier: String? = nil
}

enum CatalogUpdateOutcome: Equatable {
    case installed(version: Int)
    case alreadyCurrent(version: Int)
}

/// Download flow per handoff §3.1: manifest → version compare → download,
/// verify sha256 of the GZIPPED bytes, gunzip, sanity-probe, swap in atomically.
final class CatalogUpdater {
    let remote: CatalogRemote   // non-private: the Task 5 delta extension uses it
    private let paths: CatalogPaths
    private let fm = FileManager.default

    init(remote: CatalogRemote, paths: CatalogPaths) {
        self.remote = remote
        self.paths = paths
    }

    func installedState() -> CatalogState? {
        guard let data = try? Data(contentsOf: paths.stateURL) else { return nil }
        return try? JSONDecoder().decode(CatalogState.self, from: data)
    }

    func saveState(_ state: CatalogState) throws {
        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: paths.stateURL, options: .atomic)
    }

    /// `onProgress` fires only when a newer artifact will actually be fetched — never on the
    /// cheap already-current manifest check — so UI can show a download toast without flashing.
    /// Reports 0 as the download starts, then byte-accurate fractions against the manifest's
    /// published `sizeBytes`. Late main-actor hops can arrive out of order; the consumer keeps
    /// the value monotonic.
    ///
    /// `desiredTier` is the tier the user chose in Settings. A manifest tier that matches
    /// NEITHER the installed tier NOR the desired one can only be the casual-only Firebase
    /// fallback reached on a transient primary failure — installing it would silently downgrade
    /// a richer catalog (empty price history, missing grade columns), so it's ignored while a
    /// healthy catalog is on disk. 2026-07-18: a NAS timeout during the nightly publish window
    /// let a background refresh replace average-v14 with casual-v14 exactly this way.
    func ensureLatest(desiredTier: String = AppConfig.catalogTier,
                      onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> CatalogUpdateOutcome {
        let manifest = try await remote.fetchManifest()
        if let state = installedState(), fm.fileExists(atPath: paths.databaseURL.path) {
            let current = state.version >= manifest.version && state.tier == manifest.tier
            let unwantedTier = manifest.tier != state.tier && manifest.tier != desiredTier
            if current || unwantedTier {
                // Funding refreshes far more often than the catalog version does, so refresh it
                // here even though no download is needed — preserving version/priceAsOf.
                if let manifestFunding = manifest.funding, state.funding != manifestFunding {
                    var updated = state
                    updated.funding = manifestFunding
                    try saveState(updated)
                }
                return .alreadyCurrent(version: state.version)
            }
        }

        await onProgress?(0)
        let gz: Data
        if let onProgress {
            let expected = max(manifest.sizeBytes, 1)
            gz = try await remote.fetchData(path: manifest.path) { received in
                let fraction = min(Double(received) / Double(expected), 1)
                Task { @MainActor in onProgress(fraction) }
            }
        } else {
            gz = try await remote.fetchData(path: manifest.path)
        }
        let digest = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else { throw CatalogError.checksumMismatch }

        let sqlite: Data
        do { sqlite = try gz.gunzipped() } catch { throw CatalogError.corruptArtifact }

        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let incoming = paths.directory.appendingPathComponent("catalog-incoming.sqlite")
        try sqlite.write(to: incoming, options: .atomic)

        // Sanity probe: opens (WAL sidecars need this writable dir) and has cards.
        do {
            let probe = try CatalogStore(path: incoming.path)
            defer { try? probe.close() }
            guard try probe.cardCount() > 0 else { throw CatalogError.corruptArtifact }
        } catch let e as CatalogError { throw e } catch { throw CatalogError.corruptArtifact }

        // Drop stale WAL sidecars of the target, then swap.
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: paths.databaseURL.path + suffix))
        }
        if fm.fileExists(atPath: paths.databaseURL.path) {
            _ = try fm.replaceItemAt(paths.databaseURL, withItemAt: incoming)
        } else {
            try fm.moveItem(at: incoming, to: paths.databaseURL)
        }
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: incoming.path + suffix))
        }

        try saveState(CatalogState(version: manifest.version, priceAsOf: nil,
                                   funding: manifest.funding ?? installedState()?.funding,
                                   tier: manifest.tier))
        return .installed(version: manifest.version)
    }
}

extension CatalogUpdater {
    /// Best-effort daily price refresh; offline or missing deltas are normal, never an error.
    @discardableResult
    func refreshPrices(store: CatalogStore, dates: [String]) async -> String? {
        var state = installedState() ?? CatalogState(version: 0, priceAsOf: nil)
        var newest: String? = nil
        for date in dates.sorted() {  // apply oldest→newest so as_of ends at the latest
            if let applied = state.priceAsOf, date <= applied { continue }
            do {
                let gz = try await remote.fetchData(path: "catalog/deltas/prices-\(date).json.gz")
                let delta = try JSONDecoder().decode(PriceDelta.self, from: gz.gunzipped())
                try store.applyPriceDelta(delta)
                state.priceAsOf = delta.asOf
                newest = delta.asOf
                try saveState(state)
            } catch {
                continue // 404 (not published yet), offline, or decode issue — skip this date
            }
        }
        return newest
    }
}
