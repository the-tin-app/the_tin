import XCTest
@testable import TheTin

@MainActor
final class ScanStagingStoreTests: XCTestCase {
    private func draft(_ id: String, price: Double?) -> ScanDraft {
        ScanDraft(id: id, cardId: "ex6-58", variant: .regular, condition: .nm,
                  qty: 1, addedAt: Date(), priceUsdSnapshot: price)
    }

    func testAppendAndRunningTotal() {
        let store = ScanStagingStore.inMemory()
        store.append(draft("a", price: 10))
        store.append(draft("b", price: 2.5))
        store.append(draft("c", price: nil)) // unpriced contributes 0
        XCTAssertEqual(store.drafts.count, 3)
        XCTAssertEqual(store.totalUsd, 12.5, accuracy: 0.001)
    }

    func testRemoveAndClear() {
        let store = ScanStagingStore.inMemory()
        store.append(draft("a", price: 10))
        store.append(draft("b", price: 5))
        store.remove(id: "a")
        XCTAssertEqual(store.drafts.map(\.id), ["b"])
        store.clear()
        XCTAssertTrue(store.drafts.isEmpty)
    }

    func testUpdateVariantAndCondition() {
        let store = ScanStagingStore.inMemory()
        store.append(draft("a", price: 10))
        store.updateVariant(id: "a", .reverseHolo)
        store.updateCondition(id: "a", .lp)
        XCTAssertEqual(store.drafts.first?.variant, .reverseHolo)
        XCTAssertEqual(store.drafts.first?.condition, .lp)
    }

    func testPersistsAndReloadsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = ScanStagingPaths(fileURL: dir.appendingPathComponent("scan-staging.json"))

        let a = ScanStagingStore.persisted(paths: paths)
        a.append(ScanDraft(id: "x", cardId: "ex6-58", variant: .holo, condition: .nm,
                           qty: 1, addedAt: Date(), priceUsdSnapshot: 3.0))

        let b = ScanStagingStore.persisted(paths: paths) // fresh instance, same file
        XCTAssertEqual(b.drafts.map(\.id), ["x"])
        XCTAssertEqual(b.drafts.first?.variant, .holo)

        b.clear()
        let c = ScanStagingStore.persisted(paths: paths)
        XCTAssertTrue(c.drafts.isEmpty)
    }

    func testRepriceOnVariantEditUpdatesSnapshotAndTotal() {
        // Mirrors StagingReviewView's flow: batch-fetched fixtures drive a unitPrice resolver,
        // an edit changes the variant, reprice rewrites the snapshot the totals sum.
        let variants = [VariantPrice(printing: "Normal", usd: 10),
                        VariantPrice(printing: "Reverse Holofoil", usd: 140)]
        let price = PriceRecord(cardId: "ex6-58", rawUsd: 92.5, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-04")
        let resolve: (ScanDraft) -> Double? = { d in
            GroupStats.unitPrice(condition: d.condition, variant: d.variant,
                                 price: price, variants: variants)
        }
        let store = ScanStagingStore.inMemory()
        store.append(draft("a", price: 92.5))          // blind scan-time snapshot (raw_usd)
        store.reprice(resolve)
        XCTAssertEqual(store.drafts.first?.priceUsdSnapshot, 10)   // .regular → "Normal" printing

        store.updateVariant(id: "a", .reverseHolo)
        store.reprice(resolve)
        XCTAssertEqual(store.drafts.first?.priceUsdSnapshot, 140)  // edit repriced immediately
        XCTAssertEqual(store.totalUsd, 140, accuracy: 0.001)       // tray/review total = same numbers
    }

    func testRepriceWithNilResolverNilsAnAlreadyPricedSnapshot() {
        // Store.reprice is unconditional: it trusts whatever the resolver returns, including nil,
        // even over a draft that already had a good snapshot. That's why the "never make a
        // previously-priced draft worse" guard has to live in the caller (StagingReviewView's
        // pricesLoaded gate), not here — a resolver fed from a failed batch fetch would otherwise
        // wipe every snapshot on the next reprice() call.
        let store = ScanStagingStore.inMemory()
        store.append(draft("a", price: 92.5))
        XCTAssertEqual(store.drafts.first?.priceUsdSnapshot, 92.5)

        store.reprice { _ in nil }
        XCTAssertNil(store.drafts.first?.priceUsdSnapshot)
    }
}
