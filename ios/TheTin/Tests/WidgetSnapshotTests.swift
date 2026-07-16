import XCTest
@testable import TheTin

final class WidgetSnapshotTests: XCTestCase {
    func testRoundTripFullSnapshot() throws {
        let snap = WidgetSnapshot(totalValue: 4806.25, cardCount: 312, delta7d: 0.042,
                                  sparkline: [4390, 4510, 4806.25], asOf: "2026-07-12",
                                  updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try WidgetShared.encoder().encode(snap)
        XCTAssertEqual(try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data), snap)
    }

    func testRoundTripValueOnlySnapshot() throws {
        // What the writer produces before the portfolio-history feature merges: no delta/sparkline.
        let snap = WidgetSnapshot(totalValue: 0, cardCount: 0, delta7d: nil, sparkline: nil,
                                  asOf: nil, updatedAt: Date(timeIntervalSince1970: 0))
        let decoded = try WidgetShared.decoder()
            .decode(WidgetSnapshot.self, from: WidgetShared.encoder().encode(snap))
        XCTAssertEqual(decoded, snap)
        XCTAssertNil(decoded.delta7d)
        XCTAssertNil(decoded.sparkline)
    }

    func testTinCurrencyMatchesHeaderRules() {
        // Same rule as the Collection header: cents under $1000, whole dollars at/above.
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(WidgetShared.tinCurrency(999.5).locale(en).format(999.5), "$999.50")
        XCTAssertEqual(WidgetShared.tinCurrency(1234.56).locale(en).format(1234.56), "$1,235")
    }

    func testShortDateFallsBackToInputOnGarbage() {
        XCTAssertEqual(WidgetShared.shortDate("not-a-date"), "not-a-date")
    }

    func testShortDateFormatsInUTC() {
        XCTAssertEqual(WidgetShared.shortDate("2026-07-12"), "Jul 12")
    }
}
