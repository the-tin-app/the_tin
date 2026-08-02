import Foundation

/// `CatalogRemote` for an origin serving our manifest contract — the self-hosted `catalog-server`
/// (App Attest) or the R2 backup (App Check), which serve the same object layout and manifest
/// shape and differ only in `authorize`. Adapts the tiered manifest to the single-artifact
/// `CatalogManifest` by selecting the configured `tier`, so `CatalogUpdater` needs no changes.
/// Every call is authorized; a 401 re-authorizes (with `refresh: true`) and retries once.
struct OriginCatalogRemote: CatalogRemote {
    let baseURL: URL
    let authorize: RequestAuthorizer
    var http: HTTPClient = URLSessionHTTPClient()
    var tier: String = AppConfig.catalogTier

    /// Server manifest shape (`functions/scripts/publish-tiers.ts`), plus the two blocks
    /// `refresh-funding.ts` merges in after publish. Both are optional: they're absent on a
    /// manifest written before the nightly's step 7, and absent until the funding platform is live.
    private struct NasManifest: Decodable {
        struct Tier: Decodable { let path: String; let sha256: String; let sizeBytes: Int }
        let version: Int
        let generatedAt: String
        let tiers: [String: Tier]
        let funding: FundingSnapshot?
        let supporters: [Supporter]?
    }

    func fetchManifest() async throws -> CatalogManifest {
        let m = try JSONDecoder().decode(NasManifest.self, from: try await get("manifest.json"))
        guard let t = m.tiers[tier] else { throw CatalogError.badResponse }
        // The NAS is the only place `refresh-funding.ts` writes, so dropping these here (as this
        // did until 2026-07-25) left the nightly feed with no reader at all on the primary path.
        return CatalogManifest(version: m.version, path: t.path, sha256: t.sha256,
                               sizeBytes: t.sizeBytes, generatedAt: m.generatedAt,
                               funding: m.funding, supporters: m.supporters, tier: tier)
    }

    /// Authed manifest fetch that surfaces the version + every tier's download size — powers the
    /// Settings connection probe (auth-OK signal) and tier picker (size labels) in one round-trip.
    func fetchTierCatalog() async throws -> (version: Int, sizes: [String: Int]) {
        let m = try JSONDecoder().decode(NasManifest.self, from: try await get("manifest.json"))
        return (m.version, m.tiers.mapValues { $0.sizeBytes })
    }

    func fetchData(path: String) async throws -> Data { try await get(path) }

    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await get(path, onBytes: onBytes)
    }

    /// GET `<baseURL>/catalog/<path>`; on 401 re-authorize once and retry.
    private func get(_ path: String,
                     onBytes: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        do { return try await send(path, refresh: false, onBytes: onBytes) }
        catch CatalogError.httpStatus(401) {
            return try await send(path, refresh: true, onBytes: onBytes)
        }
    }

    private func send(_ path: String, refresh: Bool,
                      onBytes: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        let url = baseURL.appendingPathComponent("catalog").appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = AppConfig.selfHostTimeout
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
