import XCTest
@testable import TheTin

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "ai.reyes.thetin.selfhost.tests")

    override func setUp() { ["k1", "k2"].forEach(store.delete) }
    override func tearDown() { ["k1", "k2"].forEach(store.delete) }

    func testSetGetDelete() {
        XCTAssertNil(store.get("k1"))
        store.set("k1", "hello")
        XCTAssertEqual(store.get("k1"), "hello")
        store.set("k1", "world")           // overwrite
        XCTAssertEqual(store.get("k1"), "world")
        store.delete("k1")
        XCTAssertNil(store.get("k1"))
    }

    func testKeysAreIndependent() {
        store.set("k1", "a")
        store.set("k2", "b")
        XCTAssertEqual(store.get("k1"), "a")
        XCTAssertEqual(store.get("k2"), "b")
    }
}
