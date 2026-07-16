import XCTest
@testable import TheTin

/// Spec: the portfolio chart gets an existence smoke test only — it builds with a Value series
/// plus a Cost-basis overlay and the range picker hidden (PortfolioView owns the range control).
final class PortfolioChartSmokeTests: XCTestCase {
    @MainActor func testChartBuildsWithValueAndCostBasisSeries() {
        let pts = [PricePoint(date: Date(timeIntervalSince1970: 0), value: 10),
                   PricePoint(date: Date(timeIntervalSince1970: 604_800), value: 12)]
        let chart = PriceHistoryChart(series: [PriceSeries(name: "Value", points: pts),
                                               PriceSeries(name: "Cost basis", points: pts)],
                                      showsRangePicker: false)
        XCTAssertNotNil(chart.body)
    }
}
