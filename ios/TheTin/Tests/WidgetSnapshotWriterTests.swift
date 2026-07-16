import XCTest
@testable import TheTin

@MainActor
final class WidgetSnapshotWriterTests: XCTestCase {
    private func snapshot(_ v: Double) -> WidgetSnapshot {
        WidgetSnapshot(totalValue: v, cardCount: 1, delta7d: nil, sparkline: nil,
                       asOf: "2026-07-14", updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDebounceCoalescesBurstIntoOneWriteAndOneReload() async throws {
        let dir = try tempDir()
        var reloads = 0
        let writer = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(50),
                                          reload: { reloads += 1 })
        writer.schedule(snapshot(1))
        writer.schedule(snapshot(2))
        writer.schedule(snapshot(3))
        try await Task.sleep(for: .milliseconds(400))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let decoded = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.totalValue, 3)   // only the last of the burst lands
        XCTAssertEqual(reloads, 1)              // one reload, not three
    }

    func testSecondBurstAfterQuietPeriodWritesAgain() async throws {
        let dir = try tempDir()
        var reloads = 0
        let writer = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(50),
                                          reload: { reloads += 1 })
        writer.schedule(snapshot(1))
        try await Task.sleep(for: .milliseconds(400))
        writer.schedule(snapshot(2))
        try await Task.sleep(for: .milliseconds(400))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let decoded = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.totalValue, 2)
        XCTAssertEqual(reloads, 2)
    }

    func testNilContainerIsASafeNoOp() async throws {
        // Entitlement missing (e.g. a host without the App Group): never crash, never reload.
        let writer = WidgetSnapshotWriter(containerURL: nil, debounce: .milliseconds(10),
                                          reload: { XCTFail("must not reload without a container") })
        writer.schedule(snapshot(1))
        try await Task.sleep(for: .milliseconds(100))
    }
}
