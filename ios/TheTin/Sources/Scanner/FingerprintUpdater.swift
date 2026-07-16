import Foundation
import CryptoKit
import Gzip

struct FingerprintPaths {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("fingerprints.sqlite") }
    var stateURL: URL { directory.appendingPathComponent("fingerprint-state.json") }

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

enum FingerprintUpdateOutcome: Equatable {
    case installed(version: Int)
    case alreadyCurrent(version: Int)
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
        let manifest = try await remote.fetchManifest()
        guard let state = installedState() else { return false }
        return state.version >= manifest.version
            && state.fpVersion == manifest.fpVersion
            && state.codebookHash == manifest.codebookHash
            && fm.fileExists(atPath: paths.databaseURL.path)
    }

    /// `onProgress` fires only when the pack will actually be fetched — never on the cheap
    /// already-current check. Reports 0 as the download starts, then byte-accurate fractions
    /// against the manifest's published `sizeBytes` (same contract as `CatalogUpdater`). Late
    /// main-actor hops can arrive out of order; the consumer keeps the value monotonic.
    func ensureLatest(
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> FingerprintUpdateOutcome {
        let manifest = try await remote.fetchManifest()

        // Gate 0: never install a pack built against a codebook this app doesn't bundle.
        guard manifest.codebookHash == FingerprintConstants.codebookSHA256 else {
            throw CatalogError.incompatibleCodebook
        }

        if let state = installedState(),
           state.version >= manifest.version,
           state.fpVersion == manifest.fpVersion,
           state.codebookHash == manifest.codebookHash,
           fm.fileExists(atPath: paths.databaseURL.path) {
            return .alreadyCurrent(version: state.version)
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
        let incoming = paths.directory.appendingPathComponent("fingerprints-incoming.sqlite")
        try sqlite.write(to: incoming, options: .atomic)

        // Sanity probe: opens, has cards, and — critically — was built against the codebook this
        // app bundles. Gate 0 above only checks the *manifest's* claimed codebookHash; a stale
        // CDN edge or a manifest/artifact mismatch could still serve a pack whose own embedded
        // meta.codebook_hash disagrees, which would silently corrupt matching. Cross-check it here.
        do {
            let probe = try FingerprintStore(path: incoming.path)
            defer { try? probe.close() }
            guard try probe.cardCount() > 0 else { throw CatalogError.corruptArtifact }
            guard let meta = try probe.meta(), meta.codebookHash == FingerprintConstants.codebookSHA256 else {
                throw CatalogError.incompatibleCodebook
            }
        } catch let e as CatalogError { throw e } catch { throw CatalogError.corruptArtifact }

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

        try saveState(FingerprintState(version: manifest.version, fpVersion: manifest.fpVersion,
                                       codebookHash: manifest.codebookHash))
        return .installed(version: manifest.version)
    }
}
