import XCTest
@testable import TheTin

final class SmokeTests: XCTestCase {
    func testAppModuleLoads() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "ai.reyes.thetin")
    }
}
