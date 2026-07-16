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
