import Foundation

/// Frozen backend contract (handoff §3.1): manifest at `catalog/manifest.json`, artifact at
/// `catalog/catalog-vN.sqlite.gz`. The optional `funding` block mirrors the community-funding
/// health snapshot; it refreshes far more often than `version` does (see `CatalogUpdater`).
struct CatalogManifest: Codable, Equatable {
    let version: Int
    let path: String
    let sha256: String
    let sizeBytes: Int
    let generatedAt: String
    let funding: FundingSnapshot?
    /// Which tier these bytes are. Self-host stamps its configured tier; Firebase (casual-only
    /// backup) stamps "casual". Part of the installed-catalog identity so switching tiers at the
    /// same version still re-downloads (see `CatalogUpdater.ensureLatest`). Absent in legacy JSON.
    let tier: String?

    init(version: Int, path: String, sha256: String, sizeBytes: Int, generatedAt: String,
         funding: FundingSnapshot? = nil, tier: String? = nil) {
        self.version = version
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.generatedAt = generatedAt
        self.funding = funding
        self.tier = tier
    }

    func withTier(_ tier: String) -> CatalogManifest {
        CatalogManifest(version: version, path: path, sha256: sha256, sizeBytes: sizeBytes,
                        generatedAt: generatedAt, funding: funding, tier: tier)
    }
}

enum CatalogError: Error, Equatable {
    case httpStatus(Int)
    case badResponse
    case checksumMismatch
    case corruptArtifact
    case incompatibleCodebook
}

protocol CatalogRemote {
    func fetchManifest() async throws -> CatalogManifest
    func fetchData(path: String) async throws -> Data
    /// Streaming variant: `onBytes` receives the cumulative byte count as the artifact downloads
    /// (drives the download toast). Default ignores progress — only the production remotes stream.
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data
}

extension CatalogRemote {
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await fetchData(path: path)
    }
}

enum AppConfig {
    /// The org's GCP policy blocks public-read GCS buckets, so the catalog can't be served from
    /// `storage.googleapis.com` directly. It's instead served publicly via the Firebase Storage
    /// rules layer (project `hobby-tcg`), which is fronted by the Firebase Storage REST/download
    /// endpoint rather than a raw bucket URL — see `HTTPCatalogRemote.downloadURL`.
    static let catalogBaseURL = URL(string: "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o")!

    /// External donation page (Open Collective, slug matches the backend `fundingCheck` source).
    /// Opened in Safari — donations are NEVER processed in-app, and nothing is unlocked by them,
    /// which is what keeps the "Support" affordance App Store-compliant.
    // TODO: confirm the slug once the Open Collective account is approved.
    static let supportURL = URL(string: "https://opencollective.com/the-tin")!

    /// Self-hosted `catalog-server` (Cloudflare Tunnel hostname). Non-nil ⇒ the failover composite
    /// tries the NAS first and falls back to Firebase; a wrong/undeployed host just fast-fails to
    /// Firebase. Confirmed against the deployed tunnel route (see the client design spec).
    ///
    /// DEBUG builds attest in the App Attest *development* environment, which the production server
    /// (APP_ATTEST_ENVIRONMENT=production) rejects. Point a debug build at a development-environment
    /// dev server by setting `SELFHOST_URL` at launch (injected by `run-on-device.sh` from `.env`).
    static let selfHostBaseURL: URL? = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SELFHOST_URL"],
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://apithetin.reyes.ai")
    }()

    /// Per-request timeout on every self-host call; on expiry the composite falls back to Firebase.
    static let selfHostTimeout: TimeInterval = 5

    /// Which catalog tier the self-hosted client downloads: "casual" | "average" | "expert".
    /// User-changeable in Settings, persisted in UserDefaults; defaults to the average archetype
    /// (today's price + a weekly history sparkline). Read by SelfHostedCatalogRemote at construction.
    static var catalogTier: String {
        get {
            let raw = UserDefaults.standard.string(forKey: catalogTierKey) ?? ""
            return CatalogTier(rawValue: raw)?.rawValue ?? CatalogTier.average.rawValue
        }
        set { UserDefaults.standard.set(newValue, forKey: catalogTierKey) }
    }
    private static let catalogTierKey = "catalogTier"

    /// Grading fee used by the "Grade it?" panel (PSA bulk-tier default), user-editable inline.
    /// Clamped to GradingROI.feeRange on read and write. `object(forKey:)` rather than
    /// `double(forKey:)` so an explicitly saved $0 survives (double(forKey:) returns 0 for unset).
    static var gradingFeeUsd: Double {
        get {
            (UserDefaults.standard.object(forKey: gradingFeeKey) as? Double)
                .map(GradingROI.clampFee) ?? GradingROI.defaultFeeUsd
        }
        set { UserDefaults.standard.set(GradingROI.clampFee(newValue), forKey: gradingFeeKey) }
    }
    private static let gradingFeeKey = "gradingFeeUsd"

    /// Wishlist price alerts master switch (Settings toggle). Default OFF per spec — the
    /// snapshot is still maintained while off so re-enabling works instantly.
    static var priceAlertsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "priceAlertsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "priceAlertsEnabled") }
    }

    /// Alert sensitivity in whole percent — 5, 10, or 20; anything else reads as the default 10.
    static var priceAlertSensitivityPct: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: "priceAlertSensitivityPct")
            return [5, 10, 20].contains(raw) ? raw : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: "priceAlertSensitivityPct") }
    }
}

struct HTTPCatalogRemote: CatalogRemote {
    let baseURL: URL
    var session: URLSession = .shared

    func fetchManifest() async throws -> CatalogManifest {
        let m = try JSONDecoder().decode(CatalogManifest.self, from: try await get("catalog/manifest.json"))
        // Firebase is the casual-only backup; stamp it so tier-identity checks are correct.
        return m.tier == nil ? m.withTier(CatalogTier.casual.rawValue) : m
    }

    func fetchData(path: String) async throws -> Data {
        try await get(path)
    }

    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await get(path, onBytes: onBytes)
    }

    /// Builds a Firebase Storage download URL for object `path`, per the Firebase Storage REST
    /// API: `<base>/<percent-encoded-object-path>?alt=media`. The object path must collapse to a
    /// single path segment — every `/` in it is percent-encoded to `%2F` — and `alt=media` makes
    /// the endpoint return raw bytes instead of metadata JSON.
    static func downloadURL(base: URL, path: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(base.absoluteString)/\(enc)?alt=media")
    }

    private func get(_ path: String,
                     onBytes: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        guard let url = Self.downloadURL(base: baseURL, path: path) else { throw CatalogError.badResponse }
        let request = await StorageAuth.authorizedRequest(url: url)
        let (data, response): (Data, URLResponse)
        if let onBytes {
            (data, response) = try await session.dataReportingProgress(for: request, onBytes: onBytes)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        guard http.statusCode == 200 else { throw CatalogError.httpStatus(http.statusCode) }
        return data
    }
}
