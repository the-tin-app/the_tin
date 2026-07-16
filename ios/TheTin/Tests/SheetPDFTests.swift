import XCTest
import SwiftUI
import CoreGraphics
import UIKit
@testable import TheTin

final class SheetPDFTests: XCTestCase {
    // Spec §Testing: page-chunking pure test (0/1/6/7/13 items).
    func testChunkedPaginates() {
        XCTAssertEqual(([] as [Int]).chunked(into: 6).count, 0)
        XCTAssertEqual([1].chunked(into: 6), [[1]])
        XCTAssertEqual(Array(1...6).chunked(into: 6), [Array(1...6)])
        XCTAssertEqual(Array(1...7).chunked(into: 6), [Array(1...6), [7]])
        let thirteen = Array(1...13).chunked(into: 6)
        XCTAssertEqual(thirteen.map(\.count), [6, 6, 1])
        XCTAssertEqual(thirteen[2], [13])
    }

    // MARK: - Item builder fixtures (GroupStatsTests style)

    private func card(_ id: String, set: String = "swsh7", number: String = "215",
                      name: String = "Rayquaza VMAX", rarity: String? = nil) -> CardRecord {
        CardRecord(id: id, setId: set, number: number, name: name, hp: nil, types: [],
                   rarity: rarity, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    private func entry(_ id: String, card: String, qty: Int = 1, grade: String? = nil,
                       variant: CardVariant? = nil, condition: String? = "NM") -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "g1", qty: qty, condition: condition,
                        grade: grade, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date(timeIntervalSince1970: 0), variant: variant?.rawValue)
    }

    func testTradeItemsUnitPriceChipsAndSort() {
        let prices = [
            "swsh7-215": PriceRecord(cardId: "swsh7-215", rawUsd: 90, rawEur: nil, psa3: nil,
                                     psa7: nil, psa9: nil, psa10: 500, asOf: "2026-07-14"),
            "sv1-25": PriceRecord(cardId: "sv1-25", rawUsd: 2, rawEur: nil, psa3: nil,
                                  psa7: nil, psa9: nil, psa10: nil, asOf: "2026-07-14"),
        ]
        let cards = ["swsh7-215": card("swsh7-215"),
                     "sv1-25": card("sv1-25", set: "sv1", number: "25", name: "Pikachu"),
                     "swsh7-12": card("swsh7-12", number: "12", name: "Eldegoss")]
        let entries = [entry("cheap", card: "sv1-25"),
                       entry("none", card: "swsh7-12"),                        // unpriced
                       entry("big", card: "swsh7-215", qty: 3, grade: "psa10")]
        let items = PrintSheet.tradeItems(entries: entries, cards: cards,
                                          setNames: ["swsh7": "Evolving Skies", "sv1": "Scarlet & Violet"],
                                          prices: prices, variantsByCard: [:], conditionsByCard: [:])
        XCTAssertEqual(items.map(\.id), ["big", "cheap", "none"])   // entry value desc, unpriced last
        XCTAssertEqual(items[0].unitPrice, 500)                     // UNIT price, not ×3
        XCTAssertEqual(items[0].qty, 3)
        XCTAssertEqual(items[0].chips, ["NM", "PSA 10", "×3"])      // only what's set; ×qty when >1
        XCTAssertEqual(items[0].setName, "Evolving Skies")
        XCTAssertEqual(items[1].chips, ["NM"])                      // qty 1 → no ×qty chip
        XCTAssertNil(items[2].unitPrice)                            // prints "—"
    }

    func testTradeItemsVariantAndConditionChips() {
        let entries = [entry("e1", card: "swsh7-215", variant: .reverseHolo, condition: "LP")]
        let items = PrintSheet.tradeItems(entries: entries, cards: ["swsh7-215": card("swsh7-215")],
                                          setNames: [:], prices: [:], variantsByCard: [:],
                                          conditionsByCard: [:])
        XCTAssertEqual(items[0].chips, ["Reverse Holo", "LP"])
        XCTAssertEqual(items[0].setName, "swsh7")                   // set id fallback when unnamed
    }

    func testWantItemsRarityOnlyAndRawPriceSort() {
        let cards = [card("sv1-25", set: "sv1", number: "25", name: "Pikachu", rarity: "Rare"),
                     card("swsh7-215", rarity: "Rare Holo VMAX"),
                     card("swsh7-12", number: "12", name: "Eldegoss")]           // unpriced
        let prices = ["swsh7-215": PriceRecord(cardId: "swsh7-215", rawUsd: 92.5, rawEur: nil,
                                               psa3: nil, psa7: nil, psa9: nil, psa10: 505,
                                               asOf: "2026-07-14"),
                      "sv1-25": PriceRecord(cardId: "sv1-25", rawUsd: 0.4, rawEur: nil, psa3: nil,
                                            psa7: nil, psa9: nil, psa10: nil, asOf: "2026-07-14")]
        let items = PrintSheet.wantItems(cards: cards, setNames: ["swsh7": "Evolving Skies"],
                                         prices: prices)
        XCTAssertEqual(items.map(\.id), ["swsh7-215", "sv1-25", "swsh7-12"])
        XCTAssertEqual(items[0].unitPrice, 92.5)                    // NM/raw market, NOT psa10
        XCTAssertEqual(items[0].chips, ["Rare Holo VMAX"])          // rarity only
        XCTAssertEqual(items[2].chips, [])                          // nil rarity → no chip
        XCTAssertEqual(items.map(\.qty), [1, 1, 1])
    }

    // Finding 1 (final review): fetchImages must bound memory — assert the downscale helper
    // caps a large image to the ~300×420pt target and never upscales a small one.
    func testDownscaledCapsLargeImagePreservesAspectAndNeverUpscales() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 825)).image {
            UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 600, height: 825))
        }
        let capped = SheetPDF.downscaled(big)
        XCTAssertLessThanOrEqual(capped.size.width, 300)
        XCTAssertLessThanOrEqual(capped.size.height, 420)
        XCTAssertEqual(capped.size.width / capped.size.height, big.size.width / big.size.height,
                       accuracy: 0.001)

        let small = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 140)).image {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        }
        XCTAssertEqual(SheetPDF.downscaled(small).size, small.size)   // no upscale
    }

    // Spec §Testing: PDF smoke test — frame level: N input pages → N-page, non-empty PDF.
    @MainActor
    func testRenderProducesOnePDFPagePerInputPage() async throws {
        let pages = (1...2).map { n in
            SheetPage(title: "For Trade — Fixture", subtitle: "July 14, 2026",
                      contact: "Tomas · @tomas", pageNumber: n, pageCount: 2,
                      asOf: "2026-07-14") { Text("body \(n)") }
        }
        let data = await SheetPDF.render(pages: pages)
        XCTAssertFalse(data.isEmpty)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let doc = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(doc.numberOfPages, 2)
        let box = try XCTUnwrap(doc.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.size, CGSize(width: 612, height: 792))
    }

    // Spec §Testing: PDF smoke test — render fixture divider → page count + non-empty data.
    @MainActor
    func testRenderFixtureDividerPaginatesTo3Pages() async throws {
        let items: [PrintItem] = (1...13).map { i in
            let price: Double? = i == 13 ? nil : Double(i)
            let qty: Int = i == 1 ? 2 : 1
            return PrintItem(id: "e\(i)", card: card("swsh7-\(i)", number: "\(i)"),
                              setName: "Evolving Skies", chips: ["NM"], unitPrice: price, qty: qty)
        }
        let chunks = items.chunked(into: PrintSheet.cardsPerPage)
        let pages = chunks.enumerated().map { i, chunk in
            SheetPage(title: "For Trade — Fixture", subtitle: "July 14, 2026", contact: nil,
                      pageNumber: i + 1, pageCount: chunks.count, asOf: "2026-07-14") {
                SheetGridPage(items: chunk, images: [:])   // no images → bordered placeholders
            }
        }
        let data = await SheetPDF.render(pages: pages)
        XCTAssertFalse(data.isEmpty)
        let doc = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        XCTAssertEqual(doc.numberOfPages, 3)   // 13 items → 6/6/1
    }
}
