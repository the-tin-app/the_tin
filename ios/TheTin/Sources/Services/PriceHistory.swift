import Foundation

struct PricePoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// One named line on the price chart (e.g. "Raw", "NM", "PSA 10"). The first series in a chart's
/// array is the primary one (raw market) that gets the area fill; the rest are expert overlays.
struct PriceSeries: Identifiable, Equatable {
    let name: String
    let points: [PricePoint]
    var id: String { name }
}

protocol PriceHistoryProviding {
    /// Raw-price history, oldest first.
    func rawHistory(cardId: String) async throws -> [PricePoint]
}

/// Reads the local catalog's `price_history` table (offline, no network). Empty until the
/// server enrichment populates history (Plan 2c) — an empty result is normal, not an error.
struct CatalogPriceHistory: PriceHistoryProviding {
    let store: CatalogStore
    func rawHistory(cardId: String) async throws -> [PricePoint] {
        try store.priceHistory(cardId: cardId)
    }
}
