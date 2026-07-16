import XCTest
@testable import TheTin

final class OcrFieldsTests: XCTestCase {
    func testNumeratorDenominatorAndHP() {
        let f = OcrFields.from(text: "Pikachu 25/198 HP 60")
        XCTAssertTrue(f.numerators.contains("25"))
        XCTAssertEqual(f.denominator, "198")
        XCTAssertEqual(f.hp, 60)
    }

    func testLeadingZeroNumeratorKeepsBothForms() {
        let f = OcrFields.from(text: "... 025/203 ...")
        XCTAssertTrue(f.numerators.contains("025"))
        XCTAssertTrue(f.numerators.contains("25"))
        XCTAssertEqual(f.denominator, "203")
    }

    func testHPSuffixForm() {
        let f = OcrFields.from(text: "120 HP")
        XCTAssertEqual(f.hp, 120)
    }

    func testPromoAlphanumericNumerators() {
        let swsh = OcrFields.from(text: "SWSH 284")
        XCTAssertTrue(swsh.numerators.contains("SWSH284"))

        let xy = OcrFields.from(text: "XY17")
        XCTAssertTrue(xy.numerators.contains("XY17"))
    }

    func testNoNumbersProducesEmptyFields() {
        let f = OcrFields.from(text: "no numbers here")
        XCTAssertTrue(f.numerators.isEmpty)
        XCTAssertNil(f.denominator)
        XCTAssertNil(f.hp)
    }

    func testRawTextIsPreserved() {
        let f = OcrFields.from(text: "Pikachu 25/198 HP 60")
        XCTAssertEqual(f.rawText, "Pikachu 25/198 HP 60")
    }

    func testLastDenominatorWinsWhenMultipleFractions() {
        // Mirrors the reference: denom is set on each match, so the last "N/M" match wins.
        let f = OcrFields.from(text: "25/198 something 7/10")
        XCTAssertEqual(f.denominator, "10")
    }
}
