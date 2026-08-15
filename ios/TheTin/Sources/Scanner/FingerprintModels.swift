import Foundation

/// Frozen backend contract (handoff §3d): manifest at `fingerprint/manifest.json`, artifact at
/// `fingerprint/fingerprints-vN.sqlite.gz`. Superset of the catalog manifest — adds fpVersion,
/// codebookHash, and canonical dims. `sha256` is over the gzipped bytes.
struct FingerprintManifest: Codable, Equatable {
    let version: Int
    let path: String
    let sha256: String
    let sizeBytes: Int
    let generatedAt: String
    let fpVersion: Int
    let codebookHash: String
    let canonicalW: Int
    let canonicalH: Int
}

/// Manifest for the parts format (`fingerprint/parts/manifest.json`) — the pack split verbatim
/// into fixed-size, uncompressed chunks. Superset of `FingerprintManifest`'s compatibility gates
/// (version / fpVersion / codebookHash / canonical dims read identically), with two differences:
///
/// - `sha256`/`sizeBytes` describe the **assembled, uncompressed** sqlite, where the legacy
///   manifest describes gzipped bytes.
/// - `parts` carries a per-chunk sha256, so one corrupt chunk is refetched on its own instead
///   of restarting an ~800 MB download.
///
/// Concatenating parts in index order reproduces the pack byte-for-byte, so the client writes
/// each at `index * partSize` and never assembles — peak memory is one part.
struct FingerprintPartsManifest: Codable, Equatable {
    struct Part: Codable, Equatable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    let version: Int
    let partSize: Int
    let parts: [Part]
    let sha256: String
    let sizeBytes: Int
    let generatedAt: String
    let fpVersion: Int
    let codebookHash: String
    let canonicalW: Int
    let canonicalH: Int
}

protocol FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest
    /// Parts-format manifest. Throws (typically 404 / a decode failure) against a host that
    /// only serves the legacy format — `FingerprintUpdater` treats any throw as "no parts here"
    /// and falls back, so publish order and client rollout can't strand each other.
    func fetchPartsManifest() async throws -> FingerprintPartsManifest
    func fetchData(path: String) async throws -> Data
    /// Streaming variant: `onBytes` receives the cumulative byte count as the pack downloads
    /// (drives the Scan gate's progress bar). Conformers without streaming fall back to `fetchData`.
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data
}

extension FingerprintRemote {
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await fetchData(path: path)
    }

    /// Default: this host serves no parts manifest. Keeps legacy-only conformers (and the
    /// simpler test stubs) compiling unchanged.
    func fetchPartsManifest() async throws -> FingerprintPartsManifest {
        throw CatalogError.httpStatus(404)
    }
}

/// No source configured. Unreachable in a shipping build — `AppConfig.selfHostBaseURL` is a
/// parsed constant, and `ScannerPackModel.liveRemote()` falls back to the R2 backup rather than
/// this type when the NAS host is unset — but representable, so fail closed with "scanner
/// unavailable" rather than force-unwrapping.
struct UnavailableFingerprintRemote: FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest { throw CatalogError.badResponse }
    func fetchData(path: String) async throws -> Data { throw CatalogError.badResponse }
}
