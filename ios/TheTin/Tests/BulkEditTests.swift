import XCTest
@testable import TheTin

final class BulkEditTests: XCTestCase {
    private func entry(_ id: String, card: String = "c1", qty: Int = 1,
                       condition: String? = nil, grade: String? = nil, variant: String? = nil,
                       pricePaid: Double? = nil, acquiredAt: Date? = nil,
                       acquiredFrom: String? = nil, acquiredVia: String? = nil,
                       forTrade: Bool? = nil, soldAt: Date? = nil) -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "", qty: qty, condition: condition,
                        grade: grade, pricePaid: pricePaid, acquiredAt: acquiredAt,
                        acquiredFrom: acquiredFrom, addedAt: Date(), variant: variant,
                        forTrade: forTrade, soldAt: soldAt, acquiredVia: acquiredVia)
    }

    // MARK: Leave-blank means leave alone

    /// The whole safety contract of the sheet: nothing set ⇒ nothing written. A user who opens it,
    /// reads it and taps Apply must not be able to touch a single field.
    func testEmptyEditWritesNothing() {
        let rows = [entry("a", pricePaid: 12, acquiredFrom: "eBay")]
        let (updated, deleted) = BulkEdit().apply(to: rows)
        XCTAssertTrue(updated.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(BulkEdit().isEmpty)
    }

    /// Setting ONE field leaves every other field on the row exactly as it was — a bulk date fix
    /// must not quietly reset a cost basis typed in one card at a time.
    func testUnsetFieldsSurvive() {
        let rows = [entry("a", condition: "LP", variant: "holo", pricePaid: 12,
                          acquiredFrom: "eBay", acquiredVia: "bought", forTrade: true)]
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let (updated, _) = BulkEdit(acquiredAt: day).apply(to: rows)

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].acquiredAt, day)
        XCTAssertEqual(updated[0].condition, "LP")
        XCTAssertEqual(updated[0].variant, "holo")
        XCTAssertEqual(updated[0].pricePaid, 12)
        XCTAssertEqual(updated[0].acquiredFrom, "eBay")
        XCTAssertEqual(updated[0].acquiredVia, "bought")
        XCTAssertEqual(updated[0].forTrade, true)
    }

    // MARK: Price — each vs. lot

    /// `pricePaid` is a total for the row's quantity, so "$5 each" on a ×3 is $15 on that row.
    func testEachPriceMultipliesByQuantity() {
        let rows = [entry("a", qty: 1), entry("b", qty: 3)]
        let (updated, _) = BulkEdit(price: .each(5)).apply(to: rows)
        XCTAssertEqual(updated.map(\.pricePaid), [5, 15])
    }

    /// A lot splits by quantity, not by row: three copies on one row took three cards' worth of
    /// the box you bought.
    func testLotPriceSplitsByQuantity() {
        let rows = [entry("a", qty: 1), entry("b", qty: 3)]
        let (updated, _) = BulkEdit(price: .lot(100)).apply(to: rows)
        XCTAssertEqual(updated.map(\.pricePaid), [25, 75])
    }

    /// The reason the split is done in integer cents on a running total. $10 over 3 cards is
    /// $3.33 three times — a third of a cent short each time — and a cost basis that doesn't add
    /// up to what you actually handed over is worse than recording no basis at all.
    func testLotSharesSumToExactlyTheLotPrice() {
        for (total, count) in [(10.0, 3), (100.0, 7), (0.01, 4), (129.99, 6)] {
            let rows = (0..<count).map { entry("e\($0)") }
            let (updated, _) = BulkEdit(price: .lot(total)).apply(to: rows)
            let sum = updated.reduce(0) { $0 + ($1.pricePaid ?? 0) }
            XCTAssertEqual(sum, total, accuracy: 0.0001,
                           "\(total) over \(count) cards lost or invented a cent")
        }
    }

    /// A row with a nonsense quantity is still one physical card and must not take a zero share.
    func testLotSplitTreatsZeroQuantityAsOneCard() {
        let rows = [entry("a", qty: 0), entry("b", qty: 1)]
        let (updated, _) = BulkEdit(price: .lot(10)).apply(to: rows)
        XCTAssertEqual(updated.map(\.pricePaid), [5, 5])
    }

    // MARK: Slabs keep their grade as their condition

    /// A graded card's condition IS its grade, which is why `EntryFormView` hides the picker on a
    /// slab. Bulk-setting "NM" across a mixed selection must not stamp a raw condition on a PSA 9.
    func testConditionSkipsGradedCopies() {
        let rows = [entry("raw"), entry("slab", grade: "psa9")]
        let (updated, _) = BulkEdit(condition: .nm).apply(to: rows)
        XCTAssertEqual(updated.first { $0.id == "raw" }?.condition, "NM")
        XCTAssertNil(updated.first { $0.id == "slab" }?.condition)
    }

    // MARK: Sold rows are closed records

    /// A sold row's cost basis feeds realised P&L. Editing one from a bulk sheet would restate
    /// history silently, so it is dropped rather than written.
    func testSoldRowsAreNeverEdited() {
        let rows = [entry("live"), entry("gone", soldAt: Date())]
        let (updated, deleted) = BulkEdit(price: .each(5)).apply(to: rows)
        XCTAssertEqual(updated.map(\.id), ["live"])
        XCTAssertTrue(deleted.isEmpty)
    }

    /// …and a sold row must not soak up part of a lot price either — the split is over the cards
    /// you still own, or every share is wrong.
    func testSoldRowsDoNotTakeAShareOfALot() {
        let rows = [entry("live1"), entry("live2"), entry("gone", soldAt: Date())]
        let (updated, _) = BulkEdit(price: .lot(10)).apply(to: rows)
        XCTAssertEqual(updated.map(\.pricePaid), [5, 5])
    }

    // MARK: Folding rows the edit made indistinguishable

    /// Bulk-setting condition can turn two genuinely different rows into two identical ×1s of the
    /// same card — exactly the duplicate state `isSameCopy` exists to prevent, and at bulk scale
    /// it happens many times in one tap without you seeing any of them.
    func testEditFoldsRowsItMadeIdentical() {
        let rows = [entry("a", condition: "NM"), entry("b", condition: "LP")]
        let (updated, deleted) = BulkEdit(condition: .nm).apply(to: rows)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].qty, 2)
        XCTAssertEqual(deleted, ["b"])
    }

    /// Different cards are never the same copy, however identical the fields you set.
    func testFoldDoesNotCrossCards() {
        let rows = [entry("a", card: "pikachu"), entry("b", card: "charizard")]
        let (updated, deleted) = BulkEdit(condition: .nm).apply(to: rows)
        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(deleted.isEmpty)
    }

    /// The fold can never eat a price: setting one makes `hasAcquisitionDetail` true on BOTH
    /// sides, so `isSameCopy` is false and the rows stay apart with their own shares intact.
    func testLotSplitSurvivesAFoldableSelection() {
        let rows = [entry("a", condition: "NM"), entry("b", condition: "LP")]
        let (updated, deleted) = BulkEdit(price: .lot(10), condition: .nm).apply(to: rows)
        XCTAssertEqual(updated.count, 2, "rows with a cost basis must not fold into each other")
        XCTAssertEqual(updated.reduce(0) { $0 + ($1.pricePaid ?? 0) }, 10, accuracy: 0.0001)
        XCTAssertTrue(deleted.isEmpty)
    }

    /// A row carrying a per-copy fact — a photo, a centring, a price — is its own acquisition and
    /// must never be folded away by an edit to an unrelated field.
    func testFoldLeavesRowsWithAcquisitionDetailAlone() {
        let rows = [entry("a", condition: "NM", pricePaid: 40), entry("b", condition: "LP")]
        let (updated, deleted) = BulkEdit(condition: .nm).apply(to: rows)
        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(updated.first { $0.id == "a" }?.pricePaid, 40)
    }

    // MARK: The overwrite count the sheet shows before you commit

    func testOverwritesCountsRowsThatAlreadyHoldAValue() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [entry("a", acquiredAt: day), entry("b"), entry("c", acquiredAt: day)]
        XCTAssertEqual(BulkEdit(acquiredAt: Date()).overwrites(in: rows), 2)
    }

    /// Rows, not fields — one card losing both its date and its price is one card to think about.
    func testOverwritesCountsEachRowOnce() {
        let rows = [entry("a", pricePaid: 9, acquiredAt: Date())]
        XCTAssertEqual(BulkEdit(acquiredAt: Date(), price: .each(1)).overwrites(in: rows), 1)
    }

    /// Mirrors `apply`: a slab's condition is never written, so it is never reported as replaced.
    func testOverwritesIgnoresConditionOnGradedCopies() {
        let rows = [entry("slab", condition: "NM", grade: "psa9")]
        XCTAssertEqual(BulkEdit(condition: .lp).overwrites(in: rows), 0)
    }

    func testOverwritesIgnoresSoldRows() {
        let rows = [entry("gone", pricePaid: 9, soldAt: Date())]
        XCTAssertEqual(BulkEdit(price: .each(1)).overwrites(in: rows), 0)
    }

    /// Filling in blanks is not an overwrite — the line only earns its alarm when it's true.
    func testOverwritesIsZeroWhenNothingIsReplaced() {
        let rows = [entry("a"), entry("b")]
        XCTAssertEqual(BulkEdit(acquiredAt: Date(), acquiredFrom: "Chicago show",
                                acquiredVia: .bought, price: .lot(60)).overwrites(in: rows), 0)
    }

    // MARK: The shape the feature was actually asked for

    /// "I got all of these at a show on this day, for $60 the lot." One tap, six cards, a real
    /// cost basis on each and a source that says where they came from.
    func testShowPurchaseAcrossSixCards() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<6).map { entry("e\($0)", card: "c\($0)", acquiredAt: Date(timeIntervalSince1970: 0)) }
        let edit = BulkEdit(acquiredAt: day, acquiredFrom: "Chicago show",
                            acquiredVia: .bought, price: .lot(60))

        XCTAssertEqual(edit.overwrites(in: rows), 6, "every row carries a placeholder date")
        let (updated, deleted) = edit.apply(to: rows)
        XCTAssertEqual(updated.count, 6)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(updated.allSatisfy { $0.acquiredAt == day })
        XCTAssertTrue(updated.allSatisfy { $0.acquiredFrom == "Chicago show" })
        XCTAssertTrue(updated.allSatisfy { $0.acquiredViaValue == .bought })
        XCTAssertTrue(updated.allSatisfy { $0.pricePaid == 10 })
    }
}
