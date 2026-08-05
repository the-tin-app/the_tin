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
}
