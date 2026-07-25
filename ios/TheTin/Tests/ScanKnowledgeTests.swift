import XCTest
@testable import TheTin

final class ScanKnowledgeTests: XCTestCase {
    private func entry(_ id: String, card: String, qty: Int = 1) -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "g1", qty: qty, condition: "NM", grade: nil,
                        pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date(timeIntervalSince1970: 0), variant: nil)
    }

    func testUnknownCardIsNotNotableAndSaysNothing() {
        let k = ScanKnowledge.of(cardId: "swsh7-215", entries: [], wanted: [])
        XCTAssertEqual(k.ownedCount, 0)
        XCTAssertFalse(k.wanted)
        XCTAssertFalse(k.isNotable)
        XCTAssertNil(k.caption)
    }

    /// Copies are PHYSICAL cards (Σ qty across every entry for the card), matching the units the
    /// rest of the collection UI counts in — two entries of ×2 and ×1 is "you own 3", not 2.
    func testOwnedCountSumsQuantityAcrossEntries() {
        let entries = [entry("a", card: "swsh7-215", qty: 2),
                       entry("b", card: "swsh7-215", qty: 1),
                       entry("c", card: "base1-4", qty: 9)]
        let k = ScanKnowledge.of(cardId: "swsh7-215", entries: entries, wanted: [])
        XCTAssertEqual(k.ownedCount, 3)
        XCTAssertTrue(k.isNotable)
        XCTAssertEqual(k.caption, "You own 3")
    }

    func testWantedCardIsNotableEvenWhenUnowned() {
        let k = ScanKnowledge.of(cardId: "base1-4", entries: [], wanted: ["base1-4"])
        XCTAssertEqual(k.ownedCount, 0)
        XCTAssertTrue(k.wanted)
        XCTAssertTrue(k.isNotable)
        XCTAssertEqual(k.caption, "On your wishlist")
    }

    /// Wishlist leads the caption: it's the reason to buy, where the owned count is usually the
    /// reason not to.
    func testWantedAndOwnedLeadsWithTheWishlist() {
        let k = ScanKnowledge.of(cardId: "base1-4", entries: [entry("a", card: "base1-4", qty: 2)],
                                 wanted: ["base1-4"])
        XCTAssertEqual(k.caption, "On your wishlist · You own 2")
    }

    func testAnotherCardsEntriesDoNotCount() {
        let k = ScanKnowledge.of(cardId: "base1-4", entries: [entry("a", card: "swsh7-215", qty: 4)],
                                 wanted: ["swsh7-215"])
        XCTAssertEqual(k.ownedCount, 0)
        XCTAssertFalse(k.wanted)
        XCTAssertNil(k.caption)
    }
}
