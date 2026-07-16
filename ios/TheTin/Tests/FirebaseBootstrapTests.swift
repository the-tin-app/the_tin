import XCTest
@testable import TheTin

final class FirebaseBootstrapTests: XCTestCase {
    func testDetectPrefersPlist() {
        XCTAssertEqual(FirebaseMode.detect(hasPlist: true, isDebug: true), .production)
        XCTAssertEqual(FirebaseMode.detect(hasPlist: true, isDebug: false), .production)
    }

    func testDetectFallsBackToEmulatorOnlyInDebug() {
        XCTAssertEqual(FirebaseMode.detect(hasPlist: false, isDebug: true), .emulator(host: "127.0.0.1"))
        XCTAssertNil(FirebaseMode.detect(hasPlist: false, isDebug: false))
    }
}
