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

    /// Cache hits are served WITHOUT entering the actor.
    ///
    /// `Data(contentsOf:)` is synchronous disk I/O, and running it on the actor meant every
    /// lookup queued behind every other one — so a grid of forty tiles serialised its reads even
    /// when nothing was downloading. `dir` is an immutable `Sendable` `let`, so the path can be
    /// derived from outside isolation; only a genuine miss needs the actor, for in-flight
    /// bookkeeping and the download gate.
    nonisolated func image(for url: URL) async -> Data? {
        let file = Self.fileURL(for: url, in: dir)
        // Off-actor, and off the caller's thread: a cold read of a few hundred KB shouldn't run
        // wherever SwiftUI happened to call us from.
        if let data = await Task.detached(priority: .utility, operation: {
            Self.readCachedImage(at: file)
        }).value {
            return data
        }
        return await fetchMissing(url, file: file)
    }

    /// Reads a cached file, self-healing poisoned entries. Nonisolated + static: no actor state.
    ///
    /// Self-heal: a pre-fix build cached auth-error bodies (JSON) for private Firebase-Storage
    /// images as if they were art. Reject non-image bytes and re-fetch.
    private nonisolated static func readCachedImage(at file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if Self.looksLikeImage(data) { return data }
        try? FileManager.default.removeItem(at: file)
        return nil
    }

    private func fetchMissing(_ url: URL, file: URL) async -> Data? {
        ensureDirectory()
        // Coalesce: two tiles showing the same card share one download.
        if let existing = inFlight[url] { return await existing.value }
        // Re-check the disk now that we hold the actor. The fast-path read runs OFF the actor, so
        // "miss" and "register in-flight" are no longer one atomic step: a second caller can read
        // an empty cache, then arrive here after the first download has already finished and
        // cleared `inFlight`, and start a redundant fetch. `testConcurrentSameURLDownloadsOnce`
        // catches exactly that. Only the miss path pays for this read.
        if let data = Self.readCachedImage(at: file) { return data }

        let download = self.download
        let task = Task<Data?, Never> { [weak self] in
            // Wait for a slot BEFORE hitting the network. Without this every visible tile fired a
            // request at once — forty on a first load, hundreds on a fast Dex scroll — which
            // saturates the connection and starves whichever images are actually on screen.
            await self?.acquireDownloadSlot()
            defer { Task { await self?.releaseDownloadSlot() } }
            guard let data = try? await download(url), Self.looksLikeImage(data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    // MARK: - Download gate

    /// How many card images may be downloading at once.
    ///
    /// ponytail: a flat cap, not a bandwidth-aware scheduler. Four keeps a grid filling visibly
    /// fast while leaving the connection responsive for the catalog and the scanner pack; raise it
    /// only if art demonstrably lags behind scrolling on a fast network.
    private static let maxConcurrentDownloads = 4
    private var activeDownloads = 0
    private var downloadWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireDownloadSlot() async {
        if activeDownloads < Self.maxConcurrentDownloads {
            activeDownloads += 1
            return
        }
        // Resumed by `releaseDownloadSlot`, which hands its slot over rather than freeing it —
        // so the count stays exact and no waiter can be skipped.
        await withCheckedContinuation { downloadWaiters.append($0) }
    }

    private func releaseDownloadSlot() {
        if downloadWaiters.isEmpty {
            activeDownloads -= 1
        } else {
            downloadWaiters.removeFirst().resume()
        }
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

    /// Static + nonisolated so a cache hit can resolve its path without touching the actor.
    private nonisolated static func fileURL(for url: URL, in dir: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    private func fileURL(for url: URL) -> URL { Self.fileURL(for: url, in: dir) }

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
        // All card art is public: TCGdex (assets.tcgdex.net) and gap-fill (tcgplayer-cdn.tcgplayer.com).
        // No auth headers — we no longer self-host/mirror any images.
        let (data, response) = try await session.data(for: URLRequest(url: url))
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
