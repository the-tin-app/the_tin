import XCTest
@testable import TheTin

final class StageTimerTests: XCTestCase {
    func testMeasuresStagesInOrderAndSummarizes() throws {
        var timer = StageTimer()
        let x = timer.measure("detect") { 21 * 2 }
        XCTAssertEqual(x, 42)
        _ = timer.measure("ocr") { usleep(2_000) }   // ≥2ms so the reading is non-zero
        XCTAssertEqual(timer.stages.map(\.name), ["detect", "ocr"])
        XCTAssertGreaterThanOrEqual(timer.stages[1].ms, 1.0)
        XCTAssertTrue(timer.summary.contains("detect="))
        XCTAssertTrue(timer.summary.contains("ocr="))
    }

    func testRethrows() {
        struct Boom: Error {}
        var timer = StageTimer()
        XCTAssertThrowsError(try timer.measure("boom") { throw Boom() })
        XCTAssertEqual(timer.stages.count, 1)   // interval still recorded via defer
    }
}
