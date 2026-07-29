import XCTest
@testable import TheTin

final class SyncSeedingTests: XCTestCase {
    func testEmptyZoneSeedsFromThisDevice() {
        XCTAssertEqual(SyncSeeding.decide(localCount: 2610, remoteCount: 0, alreadySeeded: false),
                       .seedZone)
    }

    func testEmptyLocalPullsDown() {
        XCTAssertEqual(SyncSeeding.decide(localCount: 0, remoteCount: 2847, alreadySeeded: false),
                       .pullDown)
    }

    /// Both empty is the fresh-install case. Seeding an empty zone with an empty device is a
    /// no-op that sets the flag, which is what stops the sheet from ever appearing later.
    func testBothEmptySeeds() {
        XCTAssertEqual(SyncSeeding.decide(localCount: 0, remoteCount: 0, alreadySeeded: false),
                       .seedZone)
    }

    func testBothNonEmptyAsksWithRealCounts() {
        XCTAssertEqual(SyncSeeding.decide(localCount: 2610, remoteCount: 2847, alreadySeeded: false),
                       .ask(localCount: 2610, remoteCount: 2847))
    }

    /// The `syncSeeded` flag is the whole guarantee that no path asks twice, and that no path
    /// silently replaces a non-empty tin on a device that already made its choice.
    func testAlreadySeededNeverAsksAgain() {
        for (local, remote) in [(2610, 2847), (0, 2847), (2610, 0), (0, 0)] {
            XCTAssertEqual(SyncSeeding.decide(localCount: local, remoteCount: remote,
                                              alreadySeeded: true), SeedDecision.none,
                           "local \(local) remote \(remote) must not re-seed")
        }
    }
}
