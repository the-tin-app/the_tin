import XCTest
@testable import TheTin

final class CardVariantTests: XCTestCase {
    func testDefaultForHoloRarityIsHolo() {
        XCTAssertEqual(CardVariant.defaultFor(rarity: "Rare Holo"), .holo)
        XCTAssertEqual(CardVariant.defaultFor(rarity: "Holofoil"), .holo)
    }
    func testDefaultForNonHoloIsRegular() {
        XCTAssertEqual(CardVariant.defaultFor(rarity: "Common"), .regular)
        XCTAssertEqual(CardVariant.defaultFor(rarity: nil), .regular)
    }
    func testRawValuesStableForPersistence() {
        XCTAssertEqual(CardVariant.reverseHolo.rawValue, "reverseHolo")
        XCTAssertEqual(CardVariant(rawValue: "firstEdition"), .firstEdition)
    }
}
