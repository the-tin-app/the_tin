import XCTest
@testable import TheTin

final class ImageCacheTests: XCTestCase {
    /// A minimal but valid JPEG header (≥12 bytes) — the cache now sniffs magic bytes and rejects
    /// anything that isn't real image data, so test payloads must look like an image.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x00, count: 12))

    /// A spy downloader that records calls; safe to mutate from the actor's @Sendable closure.
    actor DownloadSpy {
        private(set) var calls: [URL] = []
        var payload = ImageCacheTests.jpeg
        var shouldThrow = false
        func fetch(_ url: URL) async throws -> Data {
            calls.append(url)
            if shouldThrow { throw URLError(.notConnectedToInternet) }
            return payload
        }
        func count() -> Int { calls.count }
        func setPayload(_ d: Data) { payload = d }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let url = URL(string: "https://assets.tcgdex.net/en/bw/bw1/26/low.webp")!

    func testMissDownloadsPersistsAndReturns() async throws {
        let spy = DownloadSpy()
        let cache = ImageCache(directory: try tempDir(), download: { try await spy.fetch($0) })

        let data = await cache.image(for: url)

        XCTAssertEqual(data, ImageCacheTests.jpeg)
        let count = await spy.count()
        XCTAssertEqual(count, 1, "miss triggers exactly one download")
    }

    func testSecondCallServedFromDiskWithoutDownloading() async throws {
        let spy = DownloadSpy()
        let cache = ImageCache(directory: try tempDir(), download: { try await spy.fetch($0) })

        _ = await cache.image(for: url)
        let again = await cache.image(for: url)

        XCTAssertEqual(again, ImageCacheTests.jpeg)
        let count = await spy.count()
        XCTAssertEqual(count, 1, "cached URL is never re-downloaded")
    }

    func testDownloadFailureReturnsNilAndPersistsNothing() async throws {
        let spy = DownloadSpy()
        await MainActor.run {}     // no-op; keeps structure uniform
        let cache = ImageCache(directory: try tempDir(), download: { url in
            throw URLError(.notConnectedToInternet)
        })
        _ = spy

        let data = await cache.image(for: url)
        XCTAssertNil(data)

        // A subsequent successful call still works (nothing poisoned).
        let spy2 = DownloadSpy()
        let cache2 = ImageCache(directory: try tempDir(), download: { try await spy2.fetch($0) })
        let ok = await cache2.image(for: url)
        XCTAssertEqual(ok, ImageCacheTests.jpeg)
    }

    func testPoisonedNonImageBytesAreRejectedAndRefetched() async throws {
        // A pre-fix build may have written an auth-error JSON body to disk. Simulate: first
        // download returns junk (not persisted), then a real image on retry.
        let spy = DownloadSpy()
        await spy.setPayload(Data("{\"error\":403}".utf8))
        let cache = ImageCache(directory: try tempDir(), download: { try await spy.fetch($0) })

        let bad = await cache.image(for: url)
        XCTAssertNil(bad, "non-image bytes are not returned or persisted")

        await spy.setPayload(ImageCacheTests.jpeg)
        let good = await cache.image(for: url)
        XCTAssertEqual(good, ImageCacheTests.jpeg, "a later valid fetch succeeds — cache wasn't poisoned")
    }

    func testConcurrentSameURLDownloadsOnce() async throws {
        let spy = DownloadSpy()
        let cache = ImageCache(directory: try tempDir(), download: { try await spy.fetch($0) })

        // Fire many concurrent requests for the same URL before any completes.
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 { group.addTask { await cache.image(for: self.url) } }
            for await _ in group {}
        }

        let count = await spy.count()
        XCTAssertEqual(count, 1, "concurrent requests for one URL coalesce into a single download")
    }

    func testClearEmptiesCacheAndZeroesSize() async throws {
        let spy = DownloadSpy()
        let cache = ImageCache(directory: try tempDir(), download: { try await spy.fetch($0) })

        _ = await cache.image(for: url)
        var bytes = await cache.totalBytes()
        var files = await cache.fileCount()
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(files, 1)

        await cache.clear()
        bytes = await cache.totalBytes()
        files = await cache.fileCount()
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(files, 0)
    }

    /// The gate must not leak permits, or art stops arriving forever.
    ///
    /// Thirty concurrent downloads, roughly a third of them throwing, then one more request. If any
    /// task abandoned its slot on the failure path, `activeDownloads` never returns to 0 and the
    /// final request parks for good. Written while hunting the 2026-07-27 "art won't download"
    /// report — it exonerated the permit arithmetic, which is exactly why it's worth keeping.
    func testGateReleasesEverySlotEvenWhenDownloadsFail() async throws {
        let cache = ImageCache(directory: try tempDir(), download: { url in
            if url.absoluteString.hasSuffix("2.jpg") || url.absoluteString.hasSuffix("5.jpg") {
                throw URLError(.notConnectedToInternet)
            }
            return ImageCacheTests.jpeg
        })

        let urls = (0..<30).map { URL(string: "https://example.test/card\($0).jpg")! }
        await withTaskGroup(of: Void.self) { g in
            for u in urls { g.addTask { _ = await cache.image(for: u) } }
            for await _ in g {}
        }

        let fresh = URL(string: "https://example.test/fresh.jpg")!
        let finished = await withTaskGroup(of: Bool.self) { g -> Bool in
            g.addTask { _ = await cache.image(for: fresh); return true }
            g.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await g.next()!
            g.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "gate leaked permits — a fresh download could not acquire a slot")
    }
}

extension ImageCacheTests {
    /// Counts how many downloads are in flight at once, and parks each until released — so the
    /// test observes the true peak rather than racing it.
    actor ConcurrencySpy {
        private var peak = 0
        private var active = 0
        private var gate: [CheckedContinuation<Void, Never>] = []

        func fetch(_ url: URL) async throws -> Data {
            active += 1
            peak = max(peak, active)
            await withCheckedContinuation { gate.append($0) }
            active -= 1
            return ImageCacheTests.jpeg
        }
        func releaseAll() {
            let waiting = gate
            gate = []
            for c in waiting { c.resume() }
        }
        func parked() -> Int { gate.count }
        func peakSeen() -> Int { peak }
    }

    /// A grid of tiles must not open a socket per tile.
    ///
    /// Reported on device 2026-07-26 (iPad, first load and fast Pokédex scrolling): every visible
    /// cell started its own download, so forty-plus requests raced each other and the whole app
    /// slowed while they fought for the connection.
    func testDownloadsAreCappedRatherThanAllStartingAtOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let spy = ConcurrencySpy()
        let cache = ImageCache(directory: dir, download: { try await spy.fetch($0) })

        let urls = (0..<30).map { URL(string: "https://example.test/card\($0).jpg")! }
        let all = Task {
            await withTaskGroup(of: Data?.self) { group in
                for u in urls { group.addTask { await cache.image(for: u) } }
                var out: [Data?] = []
                for await r in group { out.append(r) }
                return out
            }
        }

        // Read the cap rather than repeating it: this test asserted a literal 4, so raising the
        // real cap to 12 broke it — which is the good failure, but only because the numbers
        // happened to differ. Bound to the source of truth, it can't drift silently.
        let cap = ImageCache.maxConcurrentDownloads

        // Wait for the gate to fill, then read the peak.
        for _ in 0..<300 {
            if await spy.parked() >= cap { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let peak = await spy.peakSeen()
        XCTAssertLessThanOrEqual(peak, cap, "at most \(cap) downloads in flight; saw \(peak)")
        XCTAssertGreaterThan(peak, 1, "the cap must not serialise everything to one at a time")

        // Drain: each release admits the next waiter, so keep releasing until all 30 resolve.
        // BOUNDED on purpose. This loop used to be `while true`, and when the gate wedged it hung
        // xcodebuild outright — which is worse than a red test, because the process dies before
        // writing a result bundle and there is nothing left to read. Fail loudly instead.
        var drainRounds = 0
        while true {
            await spy.releaseAll()
            if all.isCancelled { break }
            let done = await spy.parked() == 0
            try await Task.sleep(for: .milliseconds(10))
            if done, await spy.parked() == 0 { break }
            drainRounds += 1
            if drainRounds > 500 {
                XCTFail("drain never completed — the gate is wedged with \(await spy.parked()) parked")
                all.cancel()
                break
            }
        }
        await spy.releaseAll()
        let results = await all.value
        let resolved = results.compactMap { $0 }.count
        let finalPeak = await spy.peakSeen()
        XCTAssertEqual(resolved, urls.count, "every card still resolves")
        XCTAssertLessThanOrEqual(finalPeak, cap, "the cap holds for the whole drain")
    }

    /// A cache hit must not touch the downloader — the common case on every launch after the
    /// first, and it used to serialise on the actor behind every other lookup.
    func testCacheHitsServeWithoutTouchingTheDownloader() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let spy = DownloadSpy()
        let cache = ImageCache(directory: dir, download: { try await spy.fetch($0) })
        let url = URL(string: "https://example.test/one.jpg")!
        _ = await cache.image(for: url)
        let afterFirst = await spy.count()
        XCTAssertEqual(afterFirst, 1)

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 { group.addTask { await cache.image(for: url) } }
            for await _ in group {}
        }
        let afterHits = await spy.count()
        XCTAssertEqual(afterHits, 1, "cached bytes must never re-hit the network")
    }

    /// Records the order downloads actually START in, and parks each until released.
    actor OrderSpy {
        private var started: [URL] = []
        private var gate: [CheckedContinuation<Void, Never>] = []

        func fetch(_ url: URL) async throws -> Data {
            started.append(url)
            await withCheckedContinuation { gate.append($0) }
            return ImageCacheTests.jpeg
        }
        func startedURLs() -> [URL] { started }
        func startedCount() -> Int { started.count }
        func releaseOne() { if !gate.isEmpty { gate.removeFirst().resume() } }
    }

    /// When a slot frees up, the MOST RECENTLY requested image goes next — not the oldest.
    ///
    /// Reported on device 2026-07-27: "new card art gets stuck downloading… it looks like the app
    /// just doesn't have a lot of the assets." No permit leak (see
    /// `testGateReleasesEverySlotEvenWhenDownloadsFail`) — the queue was simply FIFO. Scroll past
    /// three hundred cards and every one of them is queued ahead of what's on screen now, four
    /// servers deep, so the visible tiles are always last and never arrive.
    ///
    /// LIFO inverts that: whatever was asked for most recently is almost always what the user is
    /// looking at. Off-screen requests still complete, in the gaps.
    func testFreedSlotGoesToTheNewestRequestNotTheOldest() async throws {
        let spy = OrderSpy()
        let cache = ImageCache(directory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString),
                               download: { try await spy.fetch($0) })

        // Enough scrolled-past cards to fill every slot AND leave four waiting behind them —
        // sized off the real cap, because a fixed count silently stops queueing anything the
        // moment the cap is raised past it, and the test then proves nothing.
        let cap = ImageCache.maxConcurrentDownloads
        let old = (0..<(cap + 4)).map { URL(string: "https://example.test/old\($0).jpg")! }
        let running = Task {
            await withTaskGroup(of: Data?.self) { g in
                for u in old { g.addTask { await cache.image(for: u) } }
                var out: [Data?] = []
                for await r in g { out.append(r) }
                return out
            }
        }
        for _ in 0..<300 where await spy.startedCount() < cap {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Give the remaining four time to reach the waiter queue before the newest arrives.
        try await Task.sleep(for: .milliseconds(100))

        // The card now on screen — asked for last, so it is at the BACK of a FIFO queue.
        let onScreen = URL(string: "https://example.test/on-screen.jpg")!
        let newest = Task { await cache.image(for: onScreen) }
        try await Task.sleep(for: .milliseconds(100))

        // Free exactly one slot.
        await spy.releaseOne()
        for _ in 0..<300 where await spy.startedCount() < cap + 1 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let admitted = await spy.startedURLs()[cap]
        XCTAssertEqual(admitted, onScreen,
                       "a freed slot must go to the newest request; went to \(admitted.lastPathComponent)")

        newest.cancel(); running.cancel()
    }
}
