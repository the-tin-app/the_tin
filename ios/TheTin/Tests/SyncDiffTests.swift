import XCTest
@testable import TheTin

final class SyncDiffTests: XCTestCase {
    private func entry(_ id: String, qty: Int) -> CollectionEntry {
        CollectionEntry(id: id, cardId: "base1-4", groupId: "", qty: qty,
                        addedAt: Date(timeIntervalSince1970: 0))
    }

    private func records(_ entries: [CollectionEntry]) throws -> [SyncRecord] {
        try entries.map { try SyncRecord.entry($0) }
    }

    func testAddsProduceUpserts() throws {
        let current = try records([entry("a", qty: 1), entry("b", qty: 1)])
        let changes = SyncDiff.changes(previous: [:], current: current)
        XCTAssertEqual(Set(changes.upserts.map(\.recordName)), ["a", "b"])
        XCTAssertTrue(changes.deletes.isEmpty)
        XCTAssertEqual(Set(changes.hashes.keys), ["a", "b"])
    }

    func testUnchangedReEmissionProducesNothing() throws {
        let current = try records([entry("a", qty: 1)])
        let first = SyncDiff.changes(previous: [:], current: current)
        let second = SyncDiff.changes(previous: first.hashes, current: current)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(second.hashes, first.hashes)
    }

    func testEditProducesOneUpsert() throws {
        let before = try records([entry("a", qty: 1), entry("b", qty: 1)])
        let seeded = SyncDiff.changes(previous: [:], current: before)
        let after = try records([entry("a", qty: 3), entry("b", qty: 1)])
        let changes = SyncDiff.changes(previous: seeded.hashes, current: after)
        XCTAssertEqual(changes.upserts.map(\.recordName), ["a"])
        XCTAssertTrue(changes.deletes.isEmpty)
    }

    func testRemovalProducesDelete() throws {
        let seeded = SyncDiff.changes(previous: [:], current: try records([entry("a", qty: 1),
                                                                          entry("b", qty: 1)]))
        let changes = SyncDiff.changes(previous: seeded.hashes,
                                       current: try records([entry("a", qty: 1)]))
        XCTAssertEqual(changes.deletes, ["b"])
        XCTAssertTrue(changes.upserts.isEmpty)
        XCTAssertEqual(Set(changes.hashes.keys), ["a"])
    }

    /// The hash must not depend on a per-process random seed, or a relaunch would re-push the
    /// whole collection. Two independently-built records for the same value hash the same.
    func testHashIsContentAddressedNotIdentity() throws {
        let a = SyncDiff.changes(previous: [:], current: try records([entry("a", qty: 1)]))
        let b = SyncDiff.changes(previous: [:], current: try records([entry("a", qty: 1)]))
        XCTAssertEqual(a.hashes, b.hashes)
    }

    /// A payloadless record still has to diff — otherwise chasing a set never syncs and
    /// un-chasing it never deletes.
    func testPayloadlessRecordsDiff() {
        let seeded = SyncDiff.changes(previous: [:],
                                      current: [SyncRecord.setGoal("base1"),
                                                SyncRecord.setGoal("sv1")])
        XCTAssertEqual(Set(seeded.upserts.map(\.recordName)), ["base1", "sv1"])
        let changes = SyncDiff.changes(previous: seeded.hashes,
                                       current: [SyncRecord.setGoal("base1")])
        XCTAssertEqual(changes.deletes, ["sv1"])
    }

    // MARK: Echo guard

    /// Applying a remote record writes to the repository, which notifies, which diffs — and
    /// would push the record straight back. Folding the incoming records into the hash map AT
    /// APPLY TIME makes that following notify a no-op, and the loop dies on the first pass.
    func testApplyingRemoteRecordsProducesNoOutboundPush() throws {
        var hashes = SyncDiff.changes(previous: [:],
                                      current: try records([entry("a", qty: 1)])).hashes

        // A remote edit to "a" plus a remote insert of "b" arrive together.
        let incoming = try records([entry("a", qty: 9), entry("b", qty: 1)])
        SyncDiff.apply(upserts: incoming, deletes: [], to: &hashes)

        // The repository write that follows re-emits exactly what we just applied.
        let echo = SyncDiff.changes(previous: hashes, current: incoming)
        XCTAssertTrue(echo.isEmpty, "applying a remote record must not push it back")
    }

    func testApplyingRemoteDeletesProducesNoOutboundPush() throws {
        var hashes = SyncDiff.changes(previous: [:],
                                      current: try records([entry("a", qty: 1),
                                                            entry("b", qty: 1)])).hashes
        SyncDiff.apply(upserts: [], deletes: ["b"], to: &hashes)
        let echo = SyncDiff.changes(previous: hashes, current: try records([entry("a", qty: 1)]))
        XCTAssertTrue(echo.isEmpty)
    }

    /// The guard must be narrow: a LOCAL edit landing after a remote apply still pushes.
    func testLocalEditAfterApplyStillPushes() throws {
        var hashes = SyncDiff.changes(previous: [:],
                                      current: try records([entry("a", qty: 1)])).hashes
        SyncDiff.apply(upserts: try records([entry("a", qty: 9)]), deletes: [], to: &hashes)
        let changes = SyncDiff.changes(previous: hashes, current: try records([entry("a", qty: 10)]))
        XCTAssertEqual(changes.upserts.map(\.recordName), ["a"])
    }
}
