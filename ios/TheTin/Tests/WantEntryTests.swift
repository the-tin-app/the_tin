import XCTest
@testable import TheTin

final class WantEntryTests: XCTestCase {

    /// The trap this whole file exists for: a wishlist written BEFORE `hunt` existed must
    /// still decode. A defaulted non-optional would make this fail and discard the wishlist.
    func testLegacyPayloadWithoutHuntStillDecodes() throws {
        let json = Data("""
        {"priority":0,"targetUsd":300,"notes":"chase","addedAt":770000000}
        """.utf8)
        let entry = try JSONDecoder().decode(WantEntry.self, from: json)
        XCTAssertEqual(entry.priority, .high)
        XCTAssertEqual(entry.targetUsd, 300)
        XCTAssertNil(entry.hunt)
    }

    /// Grail must not disturb the stored raw values of the three existing cases, or every
    /// wishlist on every device re-reads as the wrong priority.
    func testExistingPriorityRawValuesAreUnchanged() {
        XCTAssertEqual(WantPriority.high.rawValue, 0)
        XCTAssertEqual(WantPriority.normal.rawValue, 1)
        XCTAssertEqual(WantPriority.low.rawValue, 2)
        XCTAssertEqual(WantPriority.grail.rawValue, -1)
    }

    /// `WishlistGrid.sorted(by: .priority)` sorts on rawValue ascending, so grail must lead.
    func testGrailSortsFirstAndAllCasesIsOrdered() {
        XCTAssertEqual(WantPriority.allCases, [.grail, .high, .normal, .low])
        XCTAssertLessThan(WantPriority.grail.rawValue, WantPriority.high.rawValue)
    }

    func testGrailLabel() {
        XCTAssertEqual(WantPriority.grail.label, "Grail")
    }

    func testHuntRoundTrips() throws {
        let until = Date(timeIntervalSince1970: 800_000_000)
        let entry = WantEntry(priority: .grail, targetUsd: 300, notes: "", addedAt: .distantPast,
                              hunt: Hunt(minCondition: .hp, until: until))
        let decoded = try JSONDecoder().decode(WantEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.hunt?.minCondition, .hp)
        XCTAssertEqual(decoded.hunt?.until, until)
    }

    /// Expiry is arithmetic, not a job. Boundary: `until` exactly now is still active.
    func testHuntIsActiveAcrossTheBoundary() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        XCTAssertTrue(Hunt(minCondition: .hp, until: now.addingTimeInterval(1)).isActive(now: now))
        XCTAssertTrue(Hunt(minCondition: .hp, until: now).isActive(now: now))
        XCTAssertFalse(Hunt(minCondition: .hp, until: now.addingTimeInterval(-1)).isActive(now: now))
    }
}

extension WantEntryTests {
    /// The share link encodes `priority.label.lowercased()` and `site/functions/l.js`
    /// interpolates it straight into `class="pri <value>"`. Pin the exact string the
    /// stylesheet has to match — if this changes, the CSS class silently stops applying.
    func testShareLinkPriorityTokens() {
        XCTAssertEqual(WantPriority.grail.label.lowercased(), "grail")
        XCTAssertEqual(WantPriority.high.label.lowercased(), "high")
    }
}

extension WantEntryTests {
    /// The window picker stores an ABSOLUTE date at save time, so "14 days" doesn't quietly
    /// re-mean something else every time the sheet is reopened.
    func testHuntWindowProducesAnAbsoluteDate() {
        let from = Date(timeIntervalSince1970: 800_000_000)
        XCTAssertEqual(HuntWindow.d7.until(from: from), from.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(HuntWindow.d30.until(from: from), from.addingTimeInterval(30 * 86_400))
    }

    func testHuntWindowLabels() {
        XCTAssertEqual(HuntWindow.allCases.map(\.label), ["7 days", "14 days", "30 days"])
    }
}
