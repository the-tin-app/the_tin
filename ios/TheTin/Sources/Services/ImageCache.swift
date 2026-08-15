import Foundation
import CryptoKit
import Network

/// Durable, per-device cache for card art. Persists every downloaded image to
/// Application Support keyed by sha256(url) so a URL is fetched at most once until the user
/// clears the cache (Settings). This is caching, NOT redistribution — images live only on the
/// device that fetched them. Replaces the volatile `URLCache.shared` that previously backed
/// `AsyncImage`.
actor ImageCache {
    static let shared = ImageCache()

    private let dir: URL
    private let download: @Sendable (URL) async throws -> Data
    private let isOnline: @Sendable () -> Bool
    private let fm = FileManager.default
    private var didEnsureDirectory = false
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init(directory: URL = ImageCache.defaultDirectory(),
         download: @escaping @Sendable (URL) async throws -> Data = ImageCache.defaultDownload,
         isOnline: @escaping @Sendable () -> Bool = { Reachability.shared.isSatisfied }) {
        self.dir = directory
        self.download = download
        self.isOnline = isOnline
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

        // No route: this is a known answer, not a download. Without this every missing tile pays a
        // doomed round trip before the fallback renders — and a convention hall is not airplane
        // mode, it is a captive portal, so requests do not fail, they HANG. 36 binder pockets then
        // queue three deep behind a 12-slot gate and the fact sheet arrives minutes later or never.
        //
        // ⚠️ Gates STARTING a request only. A monitor that blips unsatisfied while a download is
        // succeeding must never cancel it — the in-flight task above is untouched by this.
        guard isOnline() else { return nil }

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
    /// Was 4, which was far too tight: on device it felt "10x slower than it used to" (2026-07-27)
    /// and read as broken rather than slow. Card art comes off an HTTP/2 CDN, where parallel
    /// requests multiplex over a single connection instead of fighting for sockets — so the thing
    /// #90 actually needed to prevent was *hundreds* of requests on a fast scroll, not twelve.
    /// URLSession's own default per-host limit is 4–6 connections, so a cap of 4 was stricter than
    /// the platform would ever have been on its own.
    ///
    /// Scaled to the device, because this is really a CPU limit wearing a network limit's clothes.
    ///
    /// Every finished download is immediately decoded (`UIImage(data:)`) and cross-faded in, so the
    /// cap doesn't only govern sockets — it governs how many decodes and animations land at once.
    /// Card art comes off an HTTP/2 CDN where parallel requests multiplex over one connection, so
    /// the network was never the expensive half.
    ///
    /// One constant cannot serve both ends of the range. Measured by feel on two devices
    /// (2026-07-27): an iPad 7th gen (A10, 2 usable cores) stutters badly at 12 but was fine at 4;
    /// an iPhone 17 Pro Max (6 cores) found 4 "10x slower than it used to". Both land on
    /// cores × 2, so let the device answer instead of picking a number for whichever one
    /// complained most recently.
    ///
    /// ponytail: a heuristic fitted to two data points, not a measurement, and still not adaptive
    /// to scroll state. If a device is fast enough to want more than 12 it won't get it, and if a
    /// grid ever stutters again the next move is capping concurrent DECODES separately rather than
    /// squeezing this further — downloads are not what makes an A10 drop frames.
    ///
    /// Not private: the cap tests assert against this rather than a literal, so changing it can't
    /// silently leave a test verifying a cap that no longer exists.
    static let maxConcurrentDownloads =
        max(4, min(12, ProcessInfo.processInfo.activeProcessorCount * 2))
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

    /// Hands the slot to the NEWEST waiter, not the oldest.
    ///
    /// This was `removeFirst()` — a fair queue, and the wrong one. Nothing removes a waiter when
    /// its tile scrolls off screen (the continuation isn't cancellation-aware and the download
    /// runs in an unstructured Task the caller's cancellation never reaches), so the queue only
    /// grows. Scroll past three hundred cards and the art you are looking at is three hundredth in
    /// line behind cards you have already gone past, four servers deep — it never arrives, and the
    /// app looks like it is missing its assets. Reported on device 2026-07-27; the gate itself was
    /// exonerated of leaking permits, this was purely the order.
    ///
    /// The newest request is almost always what's on screen. Older ones still complete, in the
    /// gaps — they're off screen, so nobody is waiting on them.
    /// ponytail: ordering only. The queue is still unbounded; making the wait cancellation-aware
    /// so scrolled-away tiles drop out is the real cure, and needs a device to justify its cost.
    private func releaseDownloadSlot() {
        if downloadWaiters.isEmpty {
            activeDownloads -= 1
        } else {
            downloadWaiters.removeLast().resume()
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
        // Stock is 60 s, which is a minute of grey box per tile on bad wifi. Card art is a few
        // hundred KB off a CDN: a request still pending at 12 s was never going to land in time to
        // be useful, and giving up lets the fact sheet render instead.
        config.timeoutIntervalForRequest = 12
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

    /// Is there a route to the network at all?
    ///
    /// Lives here because `ImageCache` is its only consumer; promote it if a second one appears.
    ///
    /// ⚠️ Starts `true` and only ever becomes `false` once the monitor has actually said so. The
    /// failure mode of guessing wrong in the optimistic direction is one wasted request; guessing
    /// wrong the other way suppresses every download at launch, before the first path update
    /// lands, which would look exactly like the bug this whole change is fixing.
    final class Reachability: @unchecked Sendable {
        static let shared = Reachability()

        private let monitor = NWPathMonitor()
        private let lock = NSLock()
        private var satisfied = true

        var isSatisfied: Bool {
            lock.lock(); defer { lock.unlock() }
            return satisfied
        }

        private init() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                lock.lock(); satisfied = path.status == .satisfied; lock.unlock()
            }
            monitor.start(queue: DispatchQueue(label: "ai.reyes.thetin.reachability"))
        }
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
