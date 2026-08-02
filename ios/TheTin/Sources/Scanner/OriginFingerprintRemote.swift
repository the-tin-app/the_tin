import Foundation

/// `FingerprintRemote` for an origin serving our manifest contract — the self-hosted
/// `catalog-server` (App Attest) or the R2 backup (App Check), mirroring `OriginCatalogRemote`.
/// The scanner pack is served alongside the catalog under `/fingerprint/`; every call is
/// authorized, and a 401 re-authorizes (with `refresh: true`) and retries once.
///
/// Manifest `path` values already include the `fingerprint/` object prefix (frozen contract, same as
/// the Firebase layout in `FingerprintModels`), so `send` appends the path to `baseURL` verbatim.
struct OriginFingerprintRemote: FingerprintRemote {
    let baseURL: URL
    let authorize: RequestAuthorizer
    var http: HTTPClient = URLSessionHTTPClient()

    func fetchManifest() async throws -> FingerprintManifest {
        try JSONDecoder().decode(FingerprintManifest.self, from: try await get("fingerprint/manifest.json"))
    }

    func fetchPartsManifest() async throws -> FingerprintPartsManifest {
        try JSONDecoder().decode(FingerprintPartsManifest.self,
                                 from: try await get("fingerprint/parts/manifest.json"))
    }

    func fetchData(path: String) async throws -> Data { try await get(path) }

    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await get(path, onBytes: onBytes)
    }

    private func get(_ path: String,
                     onBytes: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        do { return try await send(path, refresh: false, onBytes: onBytes) }
        catch CatalogError.httpStatus(401) {
            return try await send(path, refresh: true, onBytes: onBytes)
        }
    }

    private func send(_ path: String, refresh: Bool,
                      onBytes: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        // The pack is ~500 MB; the catalog's 5 s per-request timeout would abort mid-download. Let
        // the SDK-less transfer run to completion (the Scan gate shows a progress bar).
        try await authorize(&req, refresh)
        let (data, response) = if let onBytes {
            try await http.send(req, onBytes: onBytes)
        } else {
            try await http.send(req)
        }
        guard response.statusCode == 200 else { throw CatalogError.httpStatus(response.statusCode) }
        return data
    }
}
