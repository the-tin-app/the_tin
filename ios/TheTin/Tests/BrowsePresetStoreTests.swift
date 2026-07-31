import XCTest
@testable import TheTin

@MainActor
final class BrowsePresetStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "preset-test-\(UUID().uuidString)")!
        return d
    }

    func testSavePersistsAcrossInstances() {
        let defaults = freshDefaults()
        var c = BrowseCriteria(); c.rarities = ["Secret Rare"]; c.sort = .priceDesc
        let store = BrowsePresetStore(defaults: defaults)
        store.save(name: "Chase secrets", criteria: c)
        XCTAssertEqual(store.presets.count, 1)

        let reloaded = BrowsePresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.presets.first?.name, "Chase secrets")
        XCTAssertEqual(reloaded.presets.first?.criteria, c)
    }

    func testRemove() {
        let defaults = freshDefaults()
        let store = BrowsePresetStore(defaults: defaults)
        store.save(name: "A", criteria: BrowseCriteria())
        let preset = store.presets[0]
        store.remove(preset)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertTrue(BrowsePresetStore(defaults: defaults).presets.isEmpty)
    }
}
