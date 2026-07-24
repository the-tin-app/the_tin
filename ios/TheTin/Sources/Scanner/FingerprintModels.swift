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

/// Mirrors HTTPCatalogRemote against the Firebase Storage download endpoint (reuses its URL helper).
struct HTTPFingerprintRemote: FingerprintRemote {
    let baseURL: URL
    var session: URLSession = .shared

    func fetchManifest() async throws -> FingerprintManifest {
        try JSONDecoder().decode(FingerprintManifest.self, from: try await get("fingerprint/manifest.json"))
    }
    func fetchData(path: String) async throws -> Data { try await get(path) }

    private func get(_ path: String) async throws -> Data {
        guard let url = HTTPCatalogRemote.downloadURL(base: baseURL, path: path) else { throw CatalogError.badResponse }
        let (data, response) = try await session.data(for: await StorageAuth.authorizedRequest(url: url))
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        guard http.statusCode == 200 else { throw CatalogError.httpStatus(http.statusCode) }
        return data
    }
}
