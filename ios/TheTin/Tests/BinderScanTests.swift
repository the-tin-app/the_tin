import XCTest
@testable import TheTin

/// The cache and the upsert rules — the two places where a wrong answer would be silent.
final class BinderScanTests: XCTestCase {

    private var root: URL!
    private var cache: BinderCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("binder-test-\(UUID().uuidString)")
        cache = BinderCache(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil; cache = nil
    }

    private func entry(_ slot: BinderSlot, _ cardId: String, inliers: Int = 30,
                       tile: String = "t1", byHand: Bool = false) -> BinderSlotEntry {
        BinderSlotEntry(slot: slot, cardId: cardId, inliers: inliers, tile: tile, byHand: byHand)
    }
    private let slot = BinderSlot(page: 0, row: 1, col: 1)

    // MARK: - put: the overlap vote

    func testTheBetterLookWinsAPocket() {
        var scan = BinderScan(shape: .default, createdAt: Date())
        scan.put(entry(slot, "weak", inliers: 22, tile: "0.0.0"))
        scan.put(entry(slot, "strong", inliers: 71, tile: "0.1.1"))
        XCTAssertEqual(scan.entry(slot)?.cardId, "strong")
        // …and the weaker second look does not displace the better first one.
        scan.put(entry(slot, "weaker", inliers: 25, tile: "0.0.0"))
        XCTAssertEqual(scan.entry(slot)?.cardId, "strong")
    }

    /// A re-shot tile replaces its OWN answer regardless of score — the user deliberately took a new
    /// photograph of that window, so it is the better evidence by definition.
    func testAReShotTileReplacesItsOwnAnswerEvenIfWeaker() {
        var scan = BinderScan(shape: .default, createdAt: Date())
        scan.put(entry(slot, "first", inliers: 80, tile: "0.0.0"))
        scan.put(entry(slot, "reshot", inliers: 21, tile: "0.0.0"))
        XCTAssertEqual(scan.entry(slot)?.cardId, "reshot")
    }

    /// ⚠️ The one that would be silent. A 3×3 or 5×5 binder photographs one row and one column TWICE,
    /// so a pocket the user has already corrected can still receive a second machine observation —
    /// and without this the correction is overwritten by the very thing it corrected.
    func testAHandPickedAnswerIsNeverOverwrittenByTheMatcher() {
        var scan = BinderScan(shape: .default, createdAt: Date())
        scan.put(entry(slot, "chosen", inliers: 0, tile: "0.0.0", byHand: true))
        scan.put(entry(slot, "machine", inliers: 99, tile: "0.1.1"))
        scan.put(entry(slot, "machine again", inliers: 99, tile: "0.0.0"))
        XCTAssertEqual(scan.entry(slot)?.cardId, "chosen")
    }

    func testAHandPickedAnswerReplacesAnything() {
        var scan = BinderScan(shape: .default, createdAt: Date())
        scan.put(entry(slot, "machine", inliers: 99))
        scan.put(entry(slot, "corrected", inliers: 0, byHand: true))
        XCTAssertEqual(scan.entry(slot)?.cardId, "corrected")
        XCTAssertEqual(scan.entries.count, 1, "put must upsert, not append a second row for one pocket")
    }

    // MARK: - The one-day cache

    func testASavedScanComesBack() {
        var scan = BinderScan(shape: BinderShape(rows: 4, cols: 4), createdAt: Date())
        scan.put(entry(slot, "sv1-25"))
        cache.save(scan)
        let loaded = cache.load()
        XCTAssertEqual(loaded?.shape, BinderShape(rows: 4, cols: 4))
        XCTAssertEqual(loaded?.entry(slot)?.cardId, "sv1-25")
    }

    /// Delete-if-stale, and the deletion is the point: by the next day a shop has replaced several
    /// cards, so an old scan is misinformation rather than history.
    func testAScanOlderThanADayIsGoneNotStale() {
        let scan = BinderScan(shape: .default, createdAt: Date())
        cache.save(scan)
        XCTAssertNil(cache.load(now: Date().addingTimeInterval(25 * 3600)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "an expired scan must be deleted, not merely hidden")
    }

    func testAScanFromAnHourAgoSurvives() {
        cache.save(BinderScan(shape: .default, createdAt: Date()))
        XCTAssertNotNil(cache.load(now: Date().addingTimeInterval(3600)))
    }

    /// A format nobody keeps for more than a day gets no migration path — so an undecodable file is
    /// deleted rather than retried every launch. This is what makes the shape free to change.
    func testAnUndecodableScanIsDeletedRatherThanRetried() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("scan.json"))
        XCTAssertNil(cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNoScanIsNotAnError() {
        XCTAssertNil(cache.load())
    }

    func testTileImagesRoundTrip() {
        cache.writeTile("0.0.0", jpeg: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try? Data(contentsOf: cache.tileURL("0.0.0")), Data([0xFF, 0xD8, 0xFF]))
        cache.clear()
        XCTAssertNil(try? Data(contentsOf: cache.tileURL("0.0.0")))
    }
}
