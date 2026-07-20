import XCTest
import Gzip
@testable import TheTin

final class PriceDeltaTests: XCTestCase {
    private var store: CatalogStore!

    override func setUpWithError() throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
    }

    override func tearDownWithError() throws { try store?.close() }

    private func delta(_ asOf: String, _ rows: [PriceDelta.Row]) -> PriceDelta {
        PriceDelta(asOf: asOf, rows: rows)
    }

    func testApplyUpdatesExistingAndInsertsNew() throws {
        let d = delta("2026-07-05", [
            .init(cardId: "swsh7-215", rawUsd: 99.0, rawEur: 90.0, psa3: nil, psa7: nil, psa9: 190, psa10: 520),
            .init(cardId: "swsh7-12", rawUsd: 0.15, rawEur: 0.13, psa3: nil, psa7: nil, psa9: nil, psa10: nil), // had NO row
        ])
        XCTAssertEqual(try store.applyPriceDelta(d), 2)
        let ray = try XCTUnwrap(store.price(cardId: "swsh7-215"))
        XCTAssertEqual(ray.rawUsd, 99.0)
        XCTAssertEqual(ray.psa10, 520)
        XCTAssertEqual(ray.asOf, "2026-07-05")
        let metapod = try XCTUnwrap(store.price(cardId: "swsh7-12"))
        XCTAssertEqual(metapod.rawUsd, 0.15)
    }

    func testUnknownCardIdsSkipped() throws {
        let d = delta("2026-07-05", [
            .init(cardId: "nope-999", rawUsd: 1, rawEur: 0.9, psa3: nil, psa7: nil, psa9: nil, psa10: nil),
            .init(cardId: "sv1-1", rawUsd: 0.25, rawEur: 0.23, psa3: nil, psa7: nil, psa9: nil, psa10: nil),
        ])
        XCTAssertEqual(try store.applyPriceDelta(d), 1)
        XCTAssertEqual(try store.price(cardId: "sv1-1")?.rawUsd, 0.25)
    }

    func testRefreshPricesFetchesDecodesAppliesAndAdvancesState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = CatalogPaths(directory: dir)
        let remote = StubRemote(manifest: CatalogManifest(version: 1, path: "x", sha256: "x",
                                                          sizeBytes: 0, generatedAt: "x"))
        let payload = PriceDelta(asOf: "2026-07-05",
                                 rows: [.init(cardId: "sv1-25", rawUsd: 0.5, rawEur: 0.45, psa3: nil, psa7: nil, psa9: nil, psa10: 16)])
        remote.files["catalog/deltas/prices-2026-07-05.json.gz"] = try JSONEncoder().encode(payload).gzipped()

        let updater = CatalogUpdater(remote: remote, paths: paths)
        try updater.saveState(CatalogState(version: 1, priceAsOf: "2026-07-04"))

        let applied = await updater.refreshPrices(store: store, dates: ["2026-07-06", "2026-07-05"])
        XCTAssertEqual(applied, "2026-07-05") // 06 was 404 → skipped, 05 applied
        XCTAssertEqual(try store.price(cardId: "sv1-25")?.rawUsd, 0.5)
        XCTAssertEqual(updater.installedState(), CatalogState(version: 1, priceAsOf: "2026-07-05"))
    }

    func testPriceDeltaRowDecodesCamelCaseWireFormat() throws {
        let json = """
        {"cardId":"x","rawUsd":1.0,"rawEur":0.9,"psa3":null,"psa7":null,"psa9":null,"psa10":null}
        """
        let row = try JSONDecoder().decode(PriceDelta.Row.self, from: Data(json.utf8))
        XCTAssertEqual(row.cardId, "x")
        XCTAssertEqual(row.rawUsd, 1.0)
        XCTAssertEqual(row.rawEur, 0.9)
        XCTAssertNil(row.psa3)
        XCTAssertNil(row.psa10)
    }

    // A row with data for *some* window keeps hasData==true even when the selected window is nil.
    // hasData gates the DeltaPeriodPicker (so the control is present to switch back to a populated
    // window) and DeltaBadge's muted "no data this window" dash — the badge no longer carries the
    // period control, so an empty window can never leave the user with no way to change it.
    func testDeltaRecordHasDataAcrossPartialWindows() {
        let only1d = DeltaRecord(kind: .psa, key: "10", pct1d: 0.12, pct7d: nil, pct30d: nil)
        XCTAssertTrue(only1d.hasData)
        XCTAssertNil(only1d.pct(for: .d30))          // selectable window with no data — must not hide the picker
        XCTAssertEqual(only1d.pct(for: .d1), 0.12)

        let empty = DeltaRecord(kind: .raw, key: "", pct1d: nil, pct7d: nil, pct30d: nil)
        XCTAssertFalse(empty.hasData)                // truly no data → badge stays absent
    }

    func testRefreshSkipsDatesAlreadyApplied() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = CatalogPaths(directory: dir)
        let remote = StubRemote(manifest: CatalogManifest(version: 1, path: "x", sha256: "x",
                                                          sizeBytes: 0, generatedAt: "x"))
        let updater = CatalogUpdater(remote: remote, paths: paths)
        try updater.saveState(CatalogState(version: 1, priceAsOf: "2026-07-05"))
        let applied = await updater.refreshPrices(store: store, dates: ["2026-07-05", "2026-07-04"])
        XCTAssertNil(applied) // nothing newer; no fetches attempted for stale dates
    }
}
