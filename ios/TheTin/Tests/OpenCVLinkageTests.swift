import XCTest
@testable import TheTin

final class OpenCVLinkageTests: XCTestCase {
    func testOpenCVLinksAndReportsVersion() {
        XCTAssertTrue(OpenCVInfo.version.hasPrefix("4.9"),
                      "expected OpenCV 4.9.x, got \(OpenCVInfo.version)")
    }
}
