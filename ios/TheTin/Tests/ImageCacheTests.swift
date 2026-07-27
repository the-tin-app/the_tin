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

        // Wait for the gate to fill, then read the peak.
        for _ in 0..<300 {
            if await spy.parked() >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let peak = await spy.peakSeen()
        XCTAssertLessThanOrEqual(peak, 4, "at most 4 downloads in flight; saw \(peak)")
        XCTAssertGreaterThan(peak, 1, "the cap must not serialise everything to one at a time")

        // Drain: each release admits the next waiter, so keep releasing until all 30 resolve.
        while true {
            await spy.releaseAll()
            if all.isCancelled { break }
            let done = await spy.parked() == 0
            try await Task.sleep(for: .milliseconds(10))
            if done, await spy.parked() == 0 { break }
        }
        await spy.releaseAll()
        let results = await all.value
        let resolved = results.compactMap { $0 }.count
        let finalPeak = await spy.peakSeen()
        XCTAssertEqual(resolved, urls.count, "every card still resolves")
        XCTAssertLessThanOrEqual(finalPeak, 4, "the cap holds for the whole drain")
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
}
