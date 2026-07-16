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

protocol FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest
    func fetchData(path: String) async throws -> Data
    /// Streaming variant: `onBytes` receives the cumulative byte count as the pack downloads
    /// (drives the Scan gate's progress bar). Conformers without streaming fall back to `fetchData`.
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data
}

extension FingerprintRemote {
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await fetchData(path: path)
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
