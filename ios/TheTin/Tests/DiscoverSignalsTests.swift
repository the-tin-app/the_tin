import XCTest
@testable import TheTin

@MainActor
final class DiscoverSignalsTests: XCTestCase {
    private func tempPaths() -> DiscoverSignalsPaths {
        DiscoverSignalsPaths(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("signals-\(UUID().uuidString).json"))
    }

    func testDismissPersistsAcrossAReload() {
        let paths = tempPaths()
        let a = DiscoverSignalsModel(paths: paths)
        a.dismiss("sv1-1")
        XCTAssertTrue(DiscoverSignalsModel(paths: paths).isDismissed("sv1-1"))
    }

    func testRestoreRemovesIt() {
        let paths = tempPaths()
        let m = DiscoverSignalsModel(paths: paths)
        m.dismiss("sv1-1")
        m.restore("sv1-1")
        XCTAssertFalse(DiscoverSignalsModel(paths: paths).isDismissed("sv1-1"))
    }

    /// The gesture is worthless if the recommendations don't recompute, and the only thing that
    /// triggers a recompute is a change in `DiscoverView.task(id:)`'s key — which counts owned and
    /// wanted cards, neither of which a dismissal changes.
    func testRevisionAdvancesOnEveryChangeSoDiscoverRecomputes() {
        let m = DiscoverSignalsModel(paths: tempPaths())
        let start = m.revision
        m.dismiss("a")
        XCTAssertGreaterThan(m.revision, start)
        let afterDismiss = m.revision
        m.restore("a")
        XCTAssertGreaterThan(m.revision, afterDismiss)
    }

    func testDismissingTheSameCardTwiceIsANoOp() {
        let m = DiscoverSignalsModel(paths: tempPaths())
        m.dismiss("a")
        let after = m.revision
        m.dismiss("a")
        XCTAssertEqual(m.revision, after, "an idempotent action must not churn the revision")
    }

    func testAMissingFileYieldsEmptySignals() {
        XCTAssertTrue(DiscoverSignalsModel(paths: tempPaths()).dismissed.isEmpty)
    }

    /// The reason this is its own file: a corrupt read costs a few thumbs-downs, not a wishlist.
    func testACorruptFileYieldsEmptySignalsAndDoesNotThrow() throws {
        let paths = tempPaths()
        try Data("{ this is not json".utf8).write(to: paths.fileURL)
        XCTAssertTrue(DiscoverSignalsModel(paths: paths).dismissed.isEmpty)
    }

    func testAFileWrittenWithoutTheFieldStillDecodes() throws {
        let paths = tempPaths()
        try Data("{}".utf8).write(to: paths.fileURL)
        XCTAssertTrue(DiscoverSignalsModel(paths: paths).dismissed.isEmpty)
    }

    // MARK: Timestamps

    /// ⚠️ The file already on the device is 99 bytes of `dismissed` + `reasons` with no timestamps
    /// at all. It has to keep decoding, and its events must keep counting at FULL strength — treating
    /// an unknown age as old would silently void every signal given before decay shipped.
    func testTheRealDeviceFileWithNoTimestampsStillDecodes() throws {
        let paths = tempPaths()
        let json = #"{"dismissed":["neo4-113","ex7-108"],"reasons":{"ex7-108":"tooExpensive"}}"#
        try Data(json.utf8).write(to: paths.fileURL)

        let m = DiscoverSignalsModel(paths: paths)
        XCTAssertEqual(m.dismissed, ["neo4-113", "ex7-108"])
        XCTAssertEqual(m.reasons["ex7-108"], .tooExpensive)
        XCTAssertTrue(m.at.isEmpty, "no stamps recorded, and that is a valid state")
    }

    func testDismissRecordsWhenAndItSurvivesAReload() {
        let paths = tempPaths()
        let stamp = Date(timeIntervalSinceReferenceDate: 807_568_576)
        let m = DiscoverSignalsModel(paths: paths)
        m.dismiss("a-1", reason: .tooExpensive, now: stamp)
        XCTAssertEqual(m.at["a-1"], stamp)

        let reloaded = DiscoverSignalsModel(paths: paths)
        XCTAssertEqual(reloaded.at["a-1"]?.timeIntervalSinceReferenceDate ?? -1,
                       stamp.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func testRestoreForgetsWhenTooSoThereIsNoOrphanStamp() {
        let paths = tempPaths()
        let m = DiscoverSignalsModel(paths: paths)
        m.dismiss("a-1", reason: .tooExpensive, now: Date())
        m.restore("a-1")
        XCTAssertNil(m.at["a-1"])
        XCTAssertNil(DiscoverSignalsModel(paths: paths).at["a-1"])
    }

    /// Attaching a reason to an already-hidden card is a NEW statement about it, so it restamps —
    /// otherwise answering the panel later would file the answer under the original hide's date and
    /// start it half-decayed.
    func testAttachingAReasonLaterRestamps() {
        let m = DiscoverSignalsModel(paths: tempPaths())
        let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let second = first.addingTimeInterval(3_600)
        m.dismiss("a-1", now: first)
        m.dismiss("a-1", reason: .tooExpensive, now: second)
        XCTAssertEqual(m.at["a-1"], second)
    }
}
