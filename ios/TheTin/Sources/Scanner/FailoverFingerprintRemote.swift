import Foundation

/// Tries the primary origin, then the backup, per call.
///
/// ⚠️ Per-CALL failover, unlike the catalog's per-OPERATION failover — and that difference is
/// deliberate. The catalog must never mix a manifest from one origin with an artifact from
/// another, because its artifact paths are version-specific and not interchangeable. The pack's
/// parts are content-addressed by the parts manifest and both origins serve byte-identical
/// objects, so a part fetched from the backup after a primary failure mid-download is the same
/// part — and re-starting a ~500 MB transfer because one part timed out would be worse.
///
/// ponytail: no origin stickiness. If the primary is down, every call pays one failed attempt
/// first. Add a short-lived "primary is down" memo only if the doubled latency shows up in a
/// real download.
struct FailoverFingerprintRemote: FingerprintRemote {
    let primary: FingerprintRemote
    let fallback: FingerprintRemote

    func fetchManifest() async throws -> FingerprintManifest {
        do { return try await primary.fetchManifest() }
        catch { return try await fallback.fetchManifest() }
    }

    func fetchPartsManifest() async throws -> FingerprintPartsManifest {
        do { return try await primary.fetchPartsManifest() }
        catch { return try await fallback.fetchPartsManifest() }
    }

    func fetchData(path: String) async throws -> Data {
        do { return try await primary.fetchData(path: path) }
        catch { return try await fallback.fetchData(path: path) }
    }

    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        do { return try await primary.fetchData(path: path, onBytes: onBytes) }
        catch { return try await fallback.fetchData(path: path, onBytes: onBytes) }
    }
}
