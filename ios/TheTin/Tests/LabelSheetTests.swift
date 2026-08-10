import UIKit
import XCTest
@testable import TheTin

final class LabelSheetTests: XCTestCase {

    private func item(_ id: String) -> LabelItem {
        LabelItem(id: id, name: "Feraligatr", setLine: "Neo Genesis · #5",
                  detail: "Holo · NM",
                  url: LabelPayload.url(cardId: "neo1-5", printing: .holo,
                                        condition: .nm, entryId: id))
    }

    /// The stock is 40 up: 1200 labels ÷ 30 sheets. A 3-column assumption prints every label
    /// off-target, so this is worth pinning.
    func testTheStockIsFortyUp() {
        XCTAssertEqual(LabelStock.spartanR005.columns, 4)
        XCTAssertEqual(LabelStock.spartanR005.rows, 10)
        XCTAssertEqual(LabelStock.spartanR005.perSheet, 40)
    }

    func testStartingAtPositionOnePutsTheFirstLabelInSlotZero() {
        let pages = LabelSheet.pages(items: [item("a")], stock: .spartanR005,
                                     startPosition: 1, offset: .zero)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].slots.count, LabelStock.spartanR005.perSheet)
        XCTAssertEqual(pages[0].slots[0]?.id, "a")
        XCTAssertNil(pages[0].slots[1])
    }

    /// A part-used sheet: twelve peeled off, so printing must start at position 13 (index 12).
    func testStartingPartWayLeavesTheUsedPositionsBlank() {
        let pages = LabelSheet.pages(items: [item("a")], stock: .spartanR005,
                                     startPosition: 13, offset: .zero)
        for i in 0..<12 { XCTAssertNil(pages[0].slots[i], "slot \(i) must stay blank") }
        XCTAssertEqual(pages[0].slots[12]?.id, "a")
    }

    /// The start offset applies to the FIRST sheet only — the second sheet is fresh stock.
    func testTheSecondSheetStartsAtItsFirstSlot() {
        let items = (0..<40).map { item("i\($0)") }
        let pages = LabelSheet.pages(items: items, stock: .spartanR005,
                                     startPosition: 39, offset: .zero)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].slots[38]?.id, "i0")
        XCTAssertEqual(pages[0].slots[39]?.id, "i1")
        XCTAssertEqual(pages[1].slots[0]?.id, "i2")
    }

    func testFortyOneItemsNeedTwoSheets() {
        let pages = LabelSheet.pages(items: (0..<41).map { item("i\($0)") },
                                     stock: .spartanR005, startPosition: 1, offset: .zero)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[1].slots.compactMap { $0 }.count, 1)
    }

    /// An out-of-range start position must not lose labels or loop forever — it clamps.
    func testAnOutOfRangeStartPositionClamps() {
        let low = LabelSheet.pages(items: [item("a")], stock: .spartanR005,
                                   startPosition: 0, offset: .zero)
        XCTAssertEqual(low[0].slots[0]?.id, "a")
        let high = LabelSheet.pages(items: [item("a")], stock: .spartanR005,
                                    startPosition: 999, offset: .zero)
        XCTAssertEqual(high.count, 1)
        XCTAssertEqual(high[0].slots[LabelStock.spartanR005.perSheet - 1]?.id, "a")
    }

    /// A ×3 entry is three physical cards and gets three labels.
    func testAQuantityEntryYieldsOneLabelPerPhysicalCard() {
        let entry = CollectionEntry(id: "e1", cardId: "neo1-5", groupId: "", qty: 3,
                                    condition: "NM", grade: nil, pricePaid: nil,
                                    acquiredAt: nil, acquiredFrom: nil,
                                    addedAt: Date(timeIntervalSince1970: 0), variant: "holo")
        let items = LabelSheet.items(entries: [entry], cards: [:], setNames: [:])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.url)).count, 1, "all three point at the same copy")
    }

    func testSoldCopiesGetNoLabel() {
        var sold = CollectionEntry(id: "e1", cardId: "neo1-5", groupId: "", qty: 1,
                                   condition: "NM", grade: nil, pricePaid: nil,
                                   acquiredAt: nil, acquiredFrom: nil,
                                   addedAt: Date(timeIntervalSince1970: 0), variant: "holo")
        sold.soldAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(LabelSheet.items(entries: [sold], cards: [:], setNames: [:]).isEmpty)
    }

    /// A card the catalog lost still gets a sticker — the label's job is to identify the thing in
    /// your hand, and dropping the row would silently print fewer labels than cards.
    func testACardTheCatalogDoesNotKnowStillGetsALabel() {
        let entry = CollectionEntry(id: "e1", cardId: "ghost-1", groupId: "", qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil,
                                    acquiredAt: nil, acquiredFrom: nil,
                                    addedAt: Date(timeIntervalSince1970: 0), variant: nil)
        let items = LabelSheet.items(entries: [entry], cards: [:], setNames: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "ghost-1")
    }

    /// The calibration knob: every label moves by the same vector, and nothing else changes.
    func testTheCalibrationOffsetShiftsEveryLabelEqually() {
        let stock = LabelStock.spartanR005
        let shift = CGSize(width: 5, height: -3)
        for index in [0, 7, 39] {
            let base = stock.origin(index: index, offset: .zero)
            let moved = stock.origin(index: index, offset: shift)
            XCTAssertEqual(moved.x - base.x, 5, accuracy: 0.001)
            XCTAssertEqual(moved.y - base.y, -3, accuracy: 0.001)
        }
    }

    func testSlotOriginsWalkLeftToRightThenDown() {
        let stock = LabelStock.spartanR005
        let first = stock.origin(index: 0, offset: .zero)
        let secondColumn = stock.origin(index: 1, offset: .zero)
        let secondRow = stock.origin(index: 4, offset: .zero)
        XCTAssertEqual(secondColumn.y, first.y, accuracy: 0.001)
        XCTAssertGreaterThan(secondColumn.x, first.x)
        XCTAssertEqual(secondRow.x, first.x, accuracy: 0.001)
        XCTAssertGreaterThan(secondRow.y, first.y)
    }

    /// The grid has to fit the paper — an arithmetic slip here wastes a whole sheet of stock.
    func testTheGridFitsOnUSLetter() {
        let stock = LabelStock.spartanR005
        let right = stock.origin(index: stock.perSheet - 1, offset: .zero).x + stock.labelSize.width
        let bottom = stock.origin(index: stock.perSheet - 1, offset: .zero).y + stock.labelSize.height
        XCTAssertLessThanOrEqual(right, SheetPDF.letter.width)
        XCTAssertLessThanOrEqual(bottom, SheetPDF.letter.height)
    }

    /// Millimetres are what a ruler reads and what Settings takes; points are what the layout
    /// uses. One inch is 25.4 mm is 72 points.
    func testMillimetresConvertToPoints() {
        XCTAssertEqual(LabelSheet.pointsPerMM(25.4), 72, accuracy: 0.001)
        XCTAssertEqual(LabelSheet.pointsPerMM(0), 0, accuracy: 0.001)
    }

    func testQRRendersAtTheRequestedSizeAndIsScannableSharp() throws {
        let url = LabelPayload.url(cardId: "sv08-057", printing: .reverseHolo,
                                   condition: .nm, entryId: UUID().uuidString)
        let image = try XCTUnwrap(LabelSheet.qrImage(for: url, size: 300))
        XCTAssertEqual(image.size.width, 300, accuracy: 1)
        XCTAssertEqual(image.size.height, 300, accuracy: 1)
    }
}
