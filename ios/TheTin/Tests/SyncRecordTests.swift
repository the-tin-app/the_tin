import XCTest
@testable import TheTin

final class SyncRecordTests: XCTestCase {
    private let group = CardGroup(id: "g1", name: "Binder", sortOrder: 2,
                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    private let entry = CollectionEntry(id: "e1", cardId: "base1-4", groupId: "g1", qty: 2,
                                        condition: "NM", grade: "psa10", pricePaid: 12.5,
                                        acquiredAt: Date(timeIntervalSince1970: 86_400),
                                        acquiredFrom: "card show",
                                        addedAt: Date(timeIntervalSince1970: 0),
                                        variant: "holo", forTrade: true)

    func testGroupRoundTrip() throws {
        let record = try SyncRecord.group(group)
        XCTAssertEqual(record.type, .group)
        XCTAssertEqual(record.recordName, "g1")
        XCTAssertEqual(try record.decode(CardGroup.self), group)
    }

    func testEntryRoundTrip() throws {
        let record = try SyncRecord.entry(entry)
        XCTAssertEqual(record.type, .entry)
        XCTAssertEqual(record.recordName, "e1")
        XCTAssertEqual(try record.decode(CollectionEntry.self), entry)
    }

    func testWantRoundTripKeyedByCardId() throws {
        let want = WantEntry(priority: .high, targetUsd: 25, notes: "grail",
                             addedAt: Date(timeIntervalSince1970: 5))
        let record = try SyncRecord.want(cardId: "sv1-25", want)
        XCTAssertEqual(record.type, .want)
        XCTAssertEqual(record.recordName, "sv1-25")
        XCTAssertEqual(try record.decode(WantEntry.self), want)
    }

    /// A set goal is a fact of existence — there is nothing to encode, and a payload would be a
    /// second copy of the record name.
    func testSetGoalCarriesNoPayload() {
        let record = SyncRecord.setGoal("base1")
        XCTAssertEqual(record.type, .setGoal)
        XCTAssertEqual(record.recordName, "base1")
        XCTAssertNil(record.payload)
    }

    /// `.sealed` exists from the start so the sealed-ownership branch merges without a schema
    /// retrofit. No storage is implemented for it here.
    func testSealedCaseExists() {
        XCTAssertEqual(SyncRecordType.sealed.rawValue, "Sealed")
        XCTAssertEqual(SyncRecordType.allCases.count, 5)
    }

    /// CloudKit record names are unique per ZONE, not per type — a want on card "base1" and a
    /// goal on set "base1" would be the same record without the type in the key.
    func testKeyNamespacesByType() throws {
        XCTAssertEqual(SyncRecord.setGoal("base1").key, "SetGoal/base1")
        XCTAssertEqual(try SyncRecord.want(cardId: "base1", WantEntry()).key, "Want/base1")
        XCTAssertNotEqual(SyncRecord.setGoal("base1").key,
                          try SyncRecord.want(cardId: "base1", WantEntry()).key)
    }

    /// The payload is what `SyncDiff` hashes, so equal models MUST encode to identical bytes.
    /// `JSONEncoder` does not guarantee that without `.sortedKeys` — key order can differ between
    /// invocations. Left unset this failed intermittently, and in the app it would have meant a
    /// full re-push of the collection on every launch plus an echo of every applied remote record.
    func testEqualModelsEncodeToIdenticalBytes() throws {
        func fresh() -> CollectionEntry {
            CollectionEntry(id: "e1", cardId: "base1-4", groupId: "g1", qty: 2, condition: "NM",
                            grade: "psa10", pricePaid: 12.5, gradingFeeUsd: 25,
                            acquiredAt: Date(timeIntervalSince1970: 86_400),
                            acquiredFrom: "card show", addedAt: Date(timeIntervalSince1970: 0),
                            variant: "holo", forTrade: true, acquiredVia: "bought")
        }
        let reference = try SyncRecord.entry(fresh()).payload
        for _ in 0..<50 {
            XCTAssertEqual(try SyncRecord.entry(fresh()).payload, reference)
        }
    }

    func testDecodeOfAPayloadlessRecordThrows() {
        XCTAssertThrowsError(try SyncRecord.setGoal("base1").decode(CardGroup.self))
    }
}
