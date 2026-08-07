import XCTest
@testable import TheTin

@MainActor
final class LensModelTests: XCTestCase {

    private func cell(_ cardId: String?, wishlist: Bool = false,
                      unreadable: String? = nil) -> LensCell {
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        let state: LensCellState = unreadable.map { .unreadable($0) }
            ?? cardId.map { .identified(cardId: $0, inliers: 40) }
            ?? .noMatch
        return LensCell(quad: q, onWishlist: wishlist, state: state)
    }

    func testRowsReflectFilterChanges() {
        let model = LensModel.forTesting()
        let p = UUID()
        model.photos[p] = [cell("a", wishlist: true), cell("b")]
        model.priceCache = ["a": 3, "b": 90]
        XCTAssertEqual(model.rows.map(\.cardId), ["a", "b"])
        model.filter.wishlistOnly = true
        XCTAssertEqual(model.rows.map(\.cardId), ["a"])
    }

    /// Failures are counted and shown, never silently dropped — a hidden miss makes the user
    /// distrust the hits the lens DID get right.
    func testUnreadableCellsAreCountedNotHidden() {
        let model = LensModel.forTesting()
        model.photos[UUID()] = [cell("a"), cell(nil, unreadable: "reflection"),
                                cell(nil, unreadable: "reflection")]
        XCTAssertEqual(model.unreadableCount, 2)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testResetClearsEverything() {
        let model = LensModel.forTesting()
        model.photos[UUID()] = [cell("a")]
        model.priceCache = ["a": 1]
        model.reset()
        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.unreadableCount, 0)
    }

    func testWishlistCountIsTheHeadlineNumber() {
        let model = LensModel.forTesting()
        model.photos[UUID()] = [cell("a", wishlist: true), cell("b", wishlist: true), cell("c")]
        XCTAssertEqual(model.wishlistHitCount, 2)
    }

    /// Rows read their display name from the model's cache, never by querying the catalog from a
    /// view body — the row struct carries the name so `body` does no I/O at all.
    func testRowsCarryTheCachedName() {
        let model = LensModel.forTesting()
        model.photos[UUID()] = [cell("a")]
        model.nameCache = ["a": "Some Card"]
        XCTAssertEqual(model.rows.first?.name, "Some Card")
    }
}
