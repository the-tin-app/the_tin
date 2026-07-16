import Foundation
import CryptoKit

/// Durable, per-device cache for card art. Persists every downloaded image to
/// Application Support keyed by sha256(url) so a URL is fetched at most once until the user
/// clears the cache (Settings). This is caching, NOT redistribution — images live only on the
/// device that fetched them. Replaces the volatile `URLCache.shared` that previously backed
/// `AsyncImage`.
actor ImageCache {
    static let shared = ImageCache()

    private let dir: URL
    private let download: @Sendable (URL) async throws -> Data
    private let fm = FileManager.default
    private var didEnsureDirectory = false
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init(directory: URL = ImageCache.defaultDirectory(),
         download: @escaping @Sendable (URL) async throws -> Data = ImageCache.defaultDownload) {
        self.dir = directory
        self.download = download
    }

    func image(for url: URL) async -> Data? {
        ensureDirectory()
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file) {
            // Self-heal: a pre-fix build cached auth-error bodies (JSON) for private
            // Firebase-Storage images as if they were art. Reject non-image bytes and re-fetch.
            if Self.looksLikeImage(data) { return data }
            try? fm.removeItem(at: file)
        }

        if let existing = inFlight[url] { return await existing.value }

        let download = self.download
        let task = Task<Data?, Never> {
            guard let data = try? await download(url), Self.looksLikeImage(data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    func totalBytes() -> Int {
        ensureDirectory()
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, f in
            sum + ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func fileCount() -> Int {
        ensureDirectory()
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    func clear() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? fm.removeItem(at: f) }
    }

    // MARK: - Paths

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    private func ensureDirectory() {
        guard !didEnsureDirectory else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        didEnsureDirectory = true
    }

    // MARK: - Default network downloader (never uses URLCache — we own persistence)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    @Sendable static func defaultDownload(_ url: URL) async throws -> Data {
        // Private mirrored art lives in our Firebase Storage bucket behind App Check + Auth
        // enforcement; a plain GET 403s. Public TCGdex art (assets.tcgdex.net) needs no headers.
        let request = url.host == "firebasestorage.googleapis.com"
            ? await StorageAuth.authorizedRequest(url: url)
            : URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Cheap magic-byte sniff — JPEG/PNG/GIF/WebP. Guards the cache from persisting error bodies
    /// (e.g. a Firebase auth-failure JSON) as if they were card art.
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8 { return true }                                   // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }       // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                     // GIF
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }     // WebP
        return false
    }
}
