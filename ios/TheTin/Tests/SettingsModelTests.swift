import XCTest
@testable import TheTin

@MainActor
final class SettingsModelTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRefreshReportsCountThenClearZeroesIt() async throws {
        // Minimal valid JPEG header (≥12 bytes): the cache now sniffs magic bytes and rejects
        // anything that isn't real image data, so the payload must look like an image to be cached.
        let cache = ImageCache(directory: try tempDir(),
                               download: { _ in Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x00, count: 12)) })
        _ = await cache.image(for: URL(string: "https://img/a.webp")!)

        let model = SettingsModel(cache: cache)
        await model.refresh()
        XCTAssertTrue(model.sizeText.contains("1 image"),
                      "expected a count of 1, got \(model.sizeText)")
        XCTAssertFalse(model.sizeText.contains("1 images"),
                       "singular form must not pluralize, got \(model.sizeText)")

        await model.clear()
        XCTAssertTrue(model.sizeText.contains("0 images"),
                      "after clear expected 0, got \(model.sizeText)")
    }
}
