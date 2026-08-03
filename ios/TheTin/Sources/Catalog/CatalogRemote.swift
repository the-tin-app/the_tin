import Foundation

/// Frozen backend contract (handoff §3.1): manifest at `catalog/manifest.json`, artifact at
/// `catalog/catalog-vN.sqlite.gz`. The optional `funding` and `supporters` blocks are refreshed
/// nightly, far more often than `version` is (see `CatalogUpdater`).
struct CatalogManifest: Codable, Equatable {
    let version: Int
    let path: String
    let sha256: String
    let sizeBytes: Int
    let generatedAt: String
    let funding: FundingSnapshot?
    /// Sponsors who asked to be listed. Served, never compiled in, so a name can be added or
    /// removed without an App Store review cycle. Absent in legacy JSON and while nobody is listed.
    let supporters: [Supporter]?
    /// Which tier these bytes are — both the self-hosted NAS and the R2 backup stamp their own
    /// configured tier (the backup carries all three, unlike the old casual-only Firebase copy).
    /// Part of the installed-catalog identity so switching tiers at the same version still
    /// re-downloads (see `CatalogUpdater.ensureLatest`). Absent in legacy JSON.
    let tier: String?

    init(version: Int, path: String, sha256: String, sizeBytes: Int, generatedAt: String,
         funding: FundingSnapshot? = nil, supporters: [Supporter]? = nil, tier: String? = nil) {
        self.version = version
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.generatedAt = generatedAt
        self.funding = funding
        self.supporters = supporters
        self.tier = tier
    }

    func withTier(_ tier: String) -> CatalogManifest {
        CatalogManifest(version: version, path: path, sha256: sha256, sizeBytes: sizeBytes,
                        generatedAt: generatedAt, funding: funding, supporters: supporters, tier: tier)
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
    /// The R2 backup origin, read through a Cloudflare Worker that verifies a Firebase App Check
    /// token. Serves the SAME object layout and the SAME tiered manifest as the NAS, which is why
    /// one remote type serves both. Its auth chain is deliberately independent of the NAS's, so a
    /// fresh install can still authenticate here while the NAS is down.
    ///
    /// ⚠️ Shipped builds pin this hostname. Changing it strands every install that has it.
    static let backupBaseURL = URL(string: "https://backupthetin.reyes.ai")!

    /// External sponsorship page. Opened in Safari — donations are NEVER processed in-app, and
    /// nothing is unlocked by them, which is what keeps the "Support" affordance App Store-
    /// compliant. Whatever links here must be *named* correctly wherever it's linked from: a
    /// button naming one platform that opens another reads as a scam.
    static let supportURL = URL(string: "https://github.com/sponsors/the-tin-app")!

    /// Self-hosted `catalog-server` (Cloudflare Tunnel hostname). Non-nil ⇒ the failover composite
    /// tries the NAS first and falls back to the R2 backup origin; a wrong/undeployed host just
    /// fast-fails to the backup. Confirmed against the deployed tunnel route (see the client design
    /// spec).
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

    /// Per-request timeout on every self-host call; on expiry the composite falls back to the R2
    /// backup origin.
    static let selfHostTimeout: TimeInterval = 5

    /// Which catalog tier the self-hosted client downloads: "casual" | "average" | "expert".
    /// User-changeable in Settings, persisted in UserDefaults; defaults to the average archetype
    /// (today's price + a weekly history sparkline). Read by OriginCatalogRemote at construction.
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

    /// Set once the user dismisses the Discover invitation to set up the scanner. The offer stays
    /// available from Settings and the Scan tab — dismissing silences the nudge, not the feature.
    static let scannerPromptDismissedKey = "scannerPromptDismissed"

    /// The catalog price date (`yyyy-MM-dd`) the user last saw on the Watching screen. Drives
    /// the Tin row's dot via `WatchingModel.hasUnseen`; written when the screen loads, so
    /// visiting is what clears it. A date rather than a count because, with no event log, a
    /// count would be permanent state that never cleared.
    static var watchingLastSeenAsOf: String? {
        get { UserDefaults.standard.string(forKey: "watchingLastSeenAsOf") }
        set { UserDefaults.standard.set(newValue, forKey: "watchingLastSeenAsOf") }
    }

    /// Scanner mode: false = stage each lock as a draft for the tin (default), true = just show
    /// the card and stage nothing. Persisted because which one you want is a property of how
    /// you're using the app today — cataloguing a box at home vs. asking "what is this?" in a
    /// shop — not of this launch.
    static var scanLookUpMode: Bool {
        get { UserDefaults.standard.bool(forKey: "scanLookUpMode") }
        set { UserDefaults.standard.set(newValue, forKey: "scanLookUpMode") }
    }

    /// The condition every scanned card is staged at. Defaults to NM — but it used to BE NM,
    /// unconditionally and invisibly, so a shoebox of played 1999 commons was valued as if it
    /// were mint and the tin total quietly inherited the lie. Sticky like `scanLookUpMode`: the
    /// condition of the stack in your hands holds for the stack, not for one card, and asking
    /// per card is exactly the per-scan tap the review screen exists to defer.
    /// An unrecognised stored value reads as NM rather than crashing an old install.
    static var scanCondition: CardCondition {
        get { CardCondition(rawValue: UserDefaults.standard.string(forKey: "scanCondition") ?? "") ?? .nm }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "scanCondition") }
    }

}

