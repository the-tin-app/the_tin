import XCTest
@testable import TheTin

final class HTTPClientTests: XCTestCase {
    func testBase64URLRoundTrip() {
        let raw = Data([0xfb, 0xff, 0xfe, 0x00, 0x10, 0x83])  // exercises + / and padding
        let encoded = Base64URL.encode(raw)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Base64URL.decode(encoded), raw)
    }

    func testBase64URLDecodesStandardVector() {
        // "Ma" -> base64url "TWE"
        XCTAssertEqual(Base64URL.decode("TWE"), Data("Ma".utf8))
    }

    func testSelfHostConfig() {
        XCTAssertEqual(AppConfig.selfHostBaseURL?.absoluteString, "https://apithetin.reyes.ai")
        XCTAssertEqual(AppConfig.selfHostTimeout, 5)
    }
}
