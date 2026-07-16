import Foundation
import FirebaseStorage

/// Fingerprint pack download via the FirebaseStorage SDK.
///
/// The `fingerprint/**` objects are auth-gated (`allow read: if request.auth != null`) on
/// top of App Check enforcement. The raw-`URLSession` path (`HTTPFingerprintRemote` +
/// `StorageAuth`) attaches the App Check token fine (the public-read catalog downloads),
/// but its hand-rolled `Authorization: Firebase <ID token>` header does **not** populate
/// `request.auth` on the REST endpoint, so the auth-gated pack 403s even when signed in
/// (verified on device: `httpStatus(403)`, `signedIn=true`). The Storage SDK attaches both
/// the App Check token and the Firebase Auth context correctly by construction.
struct StorageFingerprintRemote: FingerprintRemote {
    private let storage: Storage
    /// Cap comfortably above the pack size; the SDK rejects (does NOT download) any object
    /// larger than this. The nf=1000 v2 pack is ~789 MB (v1 was 232 MB), so 512 MB silently
    /// failed the v2 download and left the device on the stale v1 pack. Headroom for growth.
    /// NOTE: the SDK loads the whole object into memory (then gunzip → ~same again); if the
    /// pack grows much further, switch to the streaming `write(toFile:)` download.
    private let maxSize: Int64 = 2 * 1024 * 1024 * 1024

    init(storage: Storage = Storage.storage()) {
        // The SDK default silently retries failed downloads for 600 s — on the Scan gate that
        // reads as a hang. Surface real failures within a minute; the gate offers Retry.
        storage.maxDownloadRetryTime = 60
        self.storage = storage
    }

    func fetchManifest() async throws -> FingerprintManifest {
        try JSONDecoder().decode(FingerprintManifest.self, from: try await fetchData(path: "fingerprint/manifest.json"))
    }

    func fetchData(path: String) async throws -> Data {
        try await storage.reference(withPath: path).data(maxSize: maxSize)
    }

    /// Streaming variant via the task-based SDK API — `observe(.progress)` drives the Scan
    /// gate's progress bar (the async `data(maxSize:)` exposes no progress).
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        let ref = storage.reference(withPath: path)
        return try await withCheckedThrowingContinuation { cont in
            let task = ref.getData(maxSize: maxSize) { data, error in
                if let data { cont.resume(returning: data) }
                else { cont.resume(throwing: error ?? CatalogError.badResponse) }
            }
            task.observe(.progress) { snapshot in
                if let completed = snapshot.progress?.completedUnitCount, completed > 0 {
                    onBytes(Int(completed))
                }
            }
        }
    }
}
