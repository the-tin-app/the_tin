import XCTest
@testable import TheTin

final class EntryFormParseTests: XCTestCase {
    func testAmountParsing() {
        XCTAssertEqual(EntryFormView.parseAmount("12.50"), 12.5)
        XCTAssertEqual(EntryFormView.parseAmount("1,234.56"), 1234.56) // grouping — was silently dropped
        XCTAssertEqual(EntryFormView.parseAmount(" 40 "), 40)
        XCTAssertNil(EntryFormView.parseAmount(""))
        XCTAssertNil(EntryFormView.parseAmount("abc"))
    }
}
