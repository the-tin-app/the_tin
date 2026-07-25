import Foundation
import CryptoKit
import Gzip

struct FingerprintPaths {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("fingerprints.sqlite") }
    var stateURL: URL { directory.appendingPathComponent("fingerprint-state.json") }
    /// Partially-downloaded pack, written part-by-part at its final offsets. Survives app
    /// launches so a download resumes instead of restarting.
    var incomingURL: URL { directory.appendingPathComponent("fingerprints-incoming.sqlite") }
    /// Which parts of `incomingURL` have landed and verified, and which pack they belong to.
    var downloadStateURL: URL { directory.appendingPathComponent("fingerprint-download.json") }

    static func `default`() -> FingerprintPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FingerprintPaths(directory: base.appendingPathComponent("Fingerprint", isDirectory: true))
    }
}

struct FingerprintState: Codable, Equatable {
    var version: Int
    var fpVersion: Int
    var codebookHash: String
}

/// Resume ledger for an in-flight parts download. The identity fields pin the partial file to
/// one specific published pack: if any of them stops matching the server manifest, the partial
/// is for a different pack and gets discarded rather than stitched into a chimera.
struct FingerprintDownloadState: Codable, Equatable {
    var version: Int
    var fpVersion: Int
    var codebookHash: String
    var partSize: Int
    var totalBytes: Int
    /// Indices whose bytes are written at `index * partSize` and sha256-verified.
    var completedParts: [Int]

    func matches(_ manifest: FingerprintPartsManifest) -> Bool {
        version == manifest.version && fpVersion == manifest.fpVersion
            && codebookHash == manifest.codebookHash && partSize == manifest.partSize
            && totalBytes == manifest.sizeBytes
    }
}

/// Progress across a resumable download, so the UI can say "180 of 520 MB" and survive a
/// relaunch mid-download rather than restarting a bare percentage.
struct FingerprintDownloadProgress: Equatable {
    let bytesDone: Int
    let totalBytes: Int

    var fraction: Double { totalBytes > 0 ? min(Double(bytesDone) / Double(totalBytes), 1) : 0 }
}

enum FingerprintUpdateOutcome: Equatable {
    case installed(version: Int)
    case alreadyCurrent(version: Int)
}

/// What the server currently publishes, read from whichever manifest format it serves. Lets the
/// UI advertise a real download size and — more importantly — tell apart a pack that is merely
/// *older* than the published one (still perfectly usable) from one that is *incompatible*
/// (different fpVersion/codebook, would silently mismatch), which is the only case worth
/// taking someone's working scanner away for.
struct FingerprintPublishedGates: Equatable {
    let version: Int
    let fpVersion: Int
    let codebookHash: String
    let sizeBytes: Int
}

/// Mirrors CatalogUpdater's manifest→verify(gz sha256)→gunzip→probe→atomic-swap flow, with two
/// extra gates: an incompatible codebookHash (≠ the app's bundled codebook) is rejected outright,
/// and an fpVersion/codebookHash change forces re-download even at an equal `version`.
final class FingerprintUpdater {
    private let remote: FingerprintRemote
    private let paths: FingerprintPaths
    private let fm = FileManager.default

    init(remote: FingerprintRemote, paths: FingerprintPaths) {
        self.remote = remote
        self.paths = paths
    }

    func installedState() -> FingerprintState? {
        guard let data = try? Data(contentsOf: paths.stateURL) else { return nil }
        return try? JSONDecoder().decode(FingerprintState.self, from: data)
    }

    func saveState(_ state: FingerprintState) throws {
        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: paths.stateURL, options: .atomic)
    }

    /// Cheap freshness check (fetches the manifest only, never the pack): is the installed
    /// pack current w.r.t. the server manifest? The Scan gate calls this so a stale installed
    /// pack — e.g. after an fp_version bump (v1 nf=300 → v2 nf=1000) — is detected and routed
    /// to the download flow, instead of silently loading whatever pack file happens to exist.
    /// Returns false (→ needs download) when there is no installed state, the pack file is
    /// missing, or version/fpVersion/codebookHash lag the manifest.
    func isCurrent() async throws -> Bool {
        if let parts = try? await remote.fetchPartsManifest() {
            return installedIsCurrent(version: parts.version, fpVersion: parts.fpVersion,
                                      codebookHash: parts.codebookHash)
        }
        let manifest = try await remote.fetchManifest()
        return installedIsCurrent(version: manifest.version, fpVersion: manifest.fpVersion,
                                  codebookHash: manifest.codebookHash)
    }

    /// Resume ledger for an in-flight parts download, if one is pending.
    func downloadState() -> FingerprintDownloadState? {
        guard let data = try? Data(contentsOf: paths.downloadStateURL) else { return nil }
        return try? JSONDecoder().decode(FingerprintDownloadState.self, from: data)
    }

    private func saveDownloadState(_ state: FingerprintDownloadState) throws {
        try JSONEncoder().encode(state).write(to: paths.downloadStateURL, options: .atomic)
    }

    /// Drops a partial download and its ledger. Called on successful install, and whenever the
    /// partial turns out to belong to a different pack than the one now published.
    func discardPartialDownload() {
        try? fm.removeItem(at: paths.incomingURL)
        try? fm.removeItem(at: paths.downloadStateURL)
    }

    /// Removes the installed pack, its sidecars and any partial download — the Settings
    /// "reclaim this space" action. The caller must close any open `FingerprintStore` first
    /// (see `ScannerPackModel.deletePack`), or the handle outlives its file.
    func deleteInstalledPack() {
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: paths.databaseURL.path + suffix))
        }
        try? fm.removeItem(at: paths.stateURL)
        discardPartialDownload()
    }

    /// Bytes the installed pack occupies on disk, or nil when none is installed.
    func installedSizeBytes() -> Int? {
        guard let size = try? fm.attributesOfItem(atPath: paths.databaseURL.path)[.size] as? Int
        else { return nil }
        return size
    }

    /// What the host publishes right now, preferring the parts manifest. Throws when neither
    /// manifest is reachable — callers treat that as "offline, keep using what's installed".
    func publishedGates() async throws -> FingerprintPublishedGates {
        if let parts = try? await remote.fetchPartsManifest() {
            return FingerprintPublishedGates(version: parts.version, fpVersion: parts.fpVersion,
                                             codebookHash: parts.codebookHash,
                                             sizeBytes: parts.sizeBytes)
        }
        let legacy = try await remote.fetchManifest()
        return FingerprintPublishedGates(version: legacy.version, fpVersion: legacy.fpVersion,
                                         codebookHash: legacy.codebookHash,
                                         sizeBytes: legacy.sizeBytes)
    }

    /// `onProgress` fires only when the pack will actually be fetched — never on the cheap
    /// already-current check. Reports byte-accurate progress against the manifest's published
    /// size (same contract as `CatalogUpdater`); a resumed download starts at the bytes already
    /// on disk rather than at 0. Late main-actor hops can arrive out of order; the consumer
    /// keeps the value monotonic.
    ///
    /// Prefers the parts format and falls back to the legacy single-file pack when the host
    /// serves no parts manifest, so client rollout and publish order can't strand each other.
    func ensureLatest(
        onProgress: (@MainActor @Sendable (FingerprintDownloadProgress) -> Void)? = nil
    ) async throws -> FingerprintUpdateOutcome {
        // Only a *manifest* failure falls back. Once a parts manifest is in hand we commit to
        // that path: degrading mid-download would restart the whole pack through memory, which
        // is the thing the parts format exists to avoid.
        let partsManifest = try? await remote.fetchPartsManifest()
        try Task.checkCancellation()
        if let partsManifest {
            return try await install(parts: partsManifest, onProgress: onProgress)
        }
        return try await installLegacy(onProgress: onProgress)
    }

    /// True when the installed pack already satisfies a published manifest's gates.
    private func installedIsCurrent(version: Int, fpVersion: Int, codebookHash: String) -> Bool {
        guard let state = installedState() else { return false }
        return state.version >= version && state.fpVersion == fpVersion
            && state.codebookHash == codebookHash
            && fm.fileExists(atPath: paths.databaseURL.path)
    }

    // MARK: Parts format

    /// Downloads only the parts still missing, writing each at its final offset in
    /// `paths.incomingURL` and recording it in the ledger before moving on. Peak memory is one
    /// part; cancelling (pause) loses at most the part in flight.
    private func install(
        parts manifest: FingerprintPartsManifest,
        onProgress: (@MainActor @Sendable (FingerprintDownloadProgress) -> Void)?
    ) async throws -> FingerprintUpdateOutcome {
        guard manifest.codebookHash == FingerprintConstants.codebookSHA256 else {
            throw CatalogError.incompatibleCodebook
        }
        if installedIsCurrent(version: manifest.version, fpVersion: manifest.fpVersion,
                              codebookHash: manifest.codebookHash) {
            // Covers the migration case: a pack installed via the legacy format satisfies the
            // parts manifest's gates, so nobody re-downloads ~800 MB just to change format.
            return .alreadyCurrent(version: installedState()?.version ?? manifest.version)
        }

        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)

        var completed = resumableParts(for: manifest)
        var bytesDone = completed.reduce(0) { $0 + manifest.parts[$1].bytes }
        let report: (Int) -> Void = { done in
            guard let onProgress else { return }
            let p = FingerprintDownloadProgress(bytesDone: done, totalBytes: manifest.sizeBytes)
            Task { @MainActor in onProgress(p) }
        }
        report(bytesDone)

        let handle = try FileHandle(forWritingTo: paths.incomingURL)
        do {
            for (index, part) in manifest.parts.enumerated() where !completed.contains(index) {
                try Task.checkCancellation()
                let data = try await remote.fetchData(path: part.path)
                guard data.count == part.bytes, Self.hex(SHA256.hash(data: data)) == part.sha256.lowercased() else {
                    throw CatalogError.checksumMismatch
                }
                try handle.seek(toOffset: UInt64(index) * UInt64(manifest.partSize))
                try handle.write(contentsOf: data)
                try handle.synchronize()

                completed.insert(index)
                bytesDone += part.bytes
                // Persist the ledger only after the bytes are durable, so a crash can never
                // claim a part that isn't actually on disk.
                try saveDownloadState(FingerprintDownloadState(
                    version: manifest.version, fpVersion: manifest.fpVersion,
                    codebookHash: manifest.codebookHash, partSize: manifest.partSize,
                    totalBytes: manifest.sizeBytes, completedParts: completed.sorted()))
                report(bytesDone)
            }
            // Exact size even if a previous, larger pack left a longer file behind.
            try handle.truncate(atOffset: UInt64(manifest.sizeBytes))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // End-to-end gate over the assembled file. Per-part hashes already cover transport, so
        // this is really a guard on our own offset arithmetic — cheap next to the download.
        guard try Self.fileSHA256(paths.incomingURL) == manifest.sha256.lowercased() else {
            // The parts each verified, so a mismatch here means the partial is unusable rather
            // than merely incomplete — start clean instead of resuming into the same failure.
            discardPartialDownload()
            throw CatalogError.checksumMismatch
        }
        try probeIncoming()
        try swapIncomingIntoPlace()
        try saveState(FingerprintState(version: manifest.version, fpVersion: manifest.fpVersion,
                                       codebookHash: manifest.codebookHash))
        try? fm.removeItem(at: paths.downloadStateURL)
        return .installed(version: manifest.version)
    }

    /// Parts already on disk for *this* manifest. Anything else — a ledger for a different
    /// pack, a missing/short incoming file — resets to an empty file and a fresh download.
    private func resumableParts(for manifest: FingerprintPartsManifest) -> Set<Int> {
        if let state = downloadState(), state.matches(manifest),
           fm.fileExists(atPath: paths.incomingURL.path),
           // The ledger is only meaningful if the file it describes is still intact; a user who
           // cleared space (or a truncating crash) must not resume onto a hole.
           (try? fm.attributesOfItem(atPath: paths.incomingURL.path)[.size] as? Int).flatMap({ $0 }) ?? 0 >= expectedBytes(state, manifest),
           state.completedParts.allSatisfy({ $0 >= 0 && $0 < manifest.parts.count }) {
            return Set(state.completedParts)
        }
        discardPartialDownload()
        fm.createFile(atPath: paths.incomingURL.path, contents: nil)
        return []
    }

    /// Bytes the incoming file must already span to hold every part the ledger claims.
    private func expectedBytes(_ state: FingerprintDownloadState, _ manifest: FingerprintPartsManifest) -> Int {
        guard let highest = state.completedParts.max(), highest < manifest.parts.count else { return 0 }
        return highest * manifest.partSize + manifest.parts[highest].bytes
    }

    // MARK: Legacy single-file format

    private func installLegacy(
        onProgress: (@MainActor @Sendable (FingerprintDownloadProgress) -> Void)?
    ) async throws -> FingerprintUpdateOutcome {
        let manifest = try await remote.fetchManifest()

        // Gate 0: never install a pack built against a codebook this app doesn't bundle.
        guard manifest.codebookHash == FingerprintConstants.codebookSHA256 else {
            throw CatalogError.incompatibleCodebook
        }

        if installedIsCurrent(version: manifest.version, fpVersion: manifest.fpVersion,
                              codebookHash: manifest.codebookHash) {
            return .alreadyCurrent(version: installedState()?.version ?? manifest.version)
        }

        let total = max(manifest.sizeBytes, 1)
        if let onProgress {
            let zero = FingerprintDownloadProgress(bytesDone: 0, totalBytes: total)
            await onProgress(zero)
        }
        let gz: Data
        if let onProgress {
            gz = try await remote.fetchData(path: manifest.path) { received in
                let p = FingerprintDownloadProgress(bytesDone: min(received, total), totalBytes: total)
                Task { @MainActor in onProgress(p) }
            }
        } else {
            gz = try await remote.fetchData(path: manifest.path)
        }
        guard Self.hex(SHA256.hash(data: gz)) == manifest.sha256.lowercased() else {
            throw CatalogError.checksumMismatch
        }

        let sqlite: Data
        do { sqlite = try gz.gunzipped() } catch { throw CatalogError.corruptArtifact }

        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try sqlite.write(to: paths.incomingURL, options: .atomic)

        try probeIncoming()
        try swapIncomingIntoPlace()
        try saveState(FingerprintState(version: manifest.version, fpVersion: manifest.fpVersion,
                                       codebookHash: manifest.codebookHash))
        return .installed(version: manifest.version)
    }

    // MARK: Shared install tail

    /// Sanity probe: opens, has cards, and — critically — was built against the codebook this
    /// app bundles. The manifest gate only checks the *manifest's* claimed codebookHash; a stale
    /// CDN edge or a manifest/artifact mismatch could still serve a pack whose own embedded
    /// meta.codebook_hash disagrees, which would silently corrupt matching. Cross-check it here.
    private func probeIncoming() throws {
        do {
            let probe = try FingerprintStore(path: paths.incomingURL.path)
            defer { try? probe.close() }
            guard try probe.cardCount() > 0 else { throw CatalogError.corruptArtifact }
            guard let meta = try probe.meta(), meta.codebookHash == FingerprintConstants.codebookSHA256 else {
                throw CatalogError.incompatibleCodebook
            }
        } catch let e as CatalogError { throw e } catch { throw CatalogError.corruptArtifact }
    }

    private func swapIncomingIntoPlace() throws {
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: paths.databaseURL.path + suffix))
        }
        if fm.fileExists(atPath: paths.databaseURL.path) {
            _ = try fm.replaceItemAt(paths.databaseURL, withItemAt: paths.incomingURL)
        } else {
            try fm.moveItem(at: paths.incomingURL, to: paths.databaseURL)
        }
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: paths.incomingURL.path + suffix))
        }
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// sha256 of a file without loading it — the assembled pack is ~800 MB.
    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}
