import XCTest
@testable import TheTin

final class HuntingListViewTests: XCTestCase {
    /// A hunt with only a few hours left still has a day to go — "0 days left" would read as
    /// already expired. `now` is injectable so this doesn't depend on the wall clock.
    func testDaysLeftRoundsPartialDayUp() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        let hunt = Hunt(minCondition: .hp, until: now.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(HuntingListView.daysLeft(hunt, now: now), "1 day left")
    }
}
