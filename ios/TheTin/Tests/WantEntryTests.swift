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
        let entry = WantEntry(priority: .grail, targetUsd: 300, notes: "", addedAt: .distantPast,
                              hunt: Hunt(minCondition: .hp))
        let decoded = try JSONDecoder().decode(WantEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.hunt?.minCondition, .hp)
    }

    /// A hunt stored by a build that had deadlines must still decode. Codable ignores unknown
    /// keys, so `until` is simply dropped — but this is wants.json, where a decode failure makes
    /// `LocalWantsRepository.load` return `[:]` and the next write persist that empty map over
    /// the file. The Grail tier already cost us this once; it is never allowed to be theoretical.
    func testAHuntWrittenWithADeadlineStillDecodes() throws {
        let json = Data("""
        {"priority":0,"targetUsd":250,"notes":"","addedAt":770000000,
         "hunt":{"minCondition":"NM","until":770500000}}
        """.utf8)
        let entry = try JSONDecoder().decode(WantEntry.self, from: json)
        XCTAssertEqual(entry.hunt?.minCondition, .nm)
        XCTAssertEqual(entry.targetUsd, 250)
    }

    /// And a whole wishlist FILE holding such a hunt survives the repository's decoder — the
    /// layer that actually turns a decode failure into an empty wishlist.
    func testAWishlistFileWithDeadlinedHuntsIsNotEmptied() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wants-deadline-\(UUID().uuidString).json")
        try Data("""
        {"sv1-1":{"priority":0,"targetUsd":250,"notes":"","addedAt":770000000,
                  "hunt":{"minCondition":"NM","until":770500000}},
         "sv1-2":{"priority":1,"notes":"","addedAt":770000000}}
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = LocalWantsRepository.load(from: url)
        XCTAssertEqual(loaded.count, 2, "a deadlined hunt must not empty the wishlist")
        XCTAssertEqual(loaded["sv1-1"]?.hunt?.minCondition, .nm)
        XCTAssertNil(loaded["sv1-2"]?.hunt)
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

    /// `.decimalPad` shows the LOCALE's separator while `Double(_:)` only accepts "." — and
    /// `save()` drops both the target AND the hunt when the budget parses as nil, so a French
    /// user typing "300,00" lost both by pressing Done.
    func testBudgetParsesTheLocaleDecimalSeparator() {
        XCTAssertEqual(WishlistEditSheet.parseBudget("300,00", separator: ","), 300)
        XCTAssertEqual(WishlistEditSheet.parseBudget("299,99", separator: ","), 299.99)
        // A stored target is re-rendered with "%.2f" (always a dot) — it must still parse in a
        // comma locale, or reopening the sheet would clear a target it just displayed.
        XCTAssertEqual(WishlistEditSheet.parseBudget("300.00", separator: ","), 300)
        XCTAssertEqual(WishlistEditSheet.parseBudget(" 300.00 ", separator: "."), 300)
    }

    /// A non-positive or unparseable budget is no budget: a zero-target hunt would be stored,
    /// promised in the footer, then silently dropped by `huntSorted`'s `target > 0` guard.
    func testNonPositiveAndJunkBudgetsAreNil() {
        XCTAssertNil(WishlistEditSheet.parseBudget("0", separator: "."))
        XCTAssertNil(WishlistEditSheet.parseBudget("-5", separator: "."))
        XCTAssertNil(WishlistEditSheet.parseBudget("", separator: "."))
        XCTAssertNil(WishlistEditSheet.parseBudget("abc", separator: "."))
    }
}

