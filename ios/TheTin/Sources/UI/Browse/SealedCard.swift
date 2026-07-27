import SwiftUI
import UIKit

/// A URL-backed image via the durable `ImageCache` — for callers that have only a URL, not a
/// `CardRecord` (sealed products derive a TCGplayer CDN URL). Placeholder box until/unless it loads.
struct RemoteImage: View {
    let url: URL?
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fit).transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url, let data = await ImageCache.shared.image(for: url),
              let ui = UIImage(data: data) else { return }
        withAnimation(.easeOut(duration: 0.25)) { image = Image(uiImage: ui) }
    }
}

/// One sealed product as an image card: product photo, name, and market/low prices. The market
/// price is labelled so "low" sitting below it reads as the lowest listing, not an inconsistency.
/// Shared by the per-set section (`SetDetailView`) and the global `SealedListView`.
struct SealedCard: View {
    let product: SealedProduct

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: product.imageURL)
                .aspectRatio(1, contentMode: .fit) // sealed boxes are roughly square, not card-shaped
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(product.name).font(.caption).lineLimit(2)
            if let market = product.marketUsd {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(market, format: .currency(code: "USD")).font(.caption.weight(.semibold))
                    Text("market").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let low = product.lowUsd {
                Text("low \(low, format: .currency(code: "USD"))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// The global "Sealed" browse segment was deleted here (2026-07-25). It was a grid of 2,510 real,
// priced products with no tap, no heart, no add and no navigation — the app's purest dead end,
// holding a quarter of the width of its only catalog door, permanently. Sealed products are not
// ownable (`CollectionEntry` is cardId-keyed, and `isSameCopy`, the CSV round-trip, the backup
// schema, the widget snapshot and the share links all inherit that), and making them ownable is
// multi-day data-model work nobody has asked for.
//
// The data still earns its place on `SetDetailView`, where it reads as context for a set you're
// already looking at rather than as a promise the app doesn't keep. `CatalogStore.
// allSealedProducts()` is kept and still tested — it's the query a future owning feature starts
// from, and deleting it would be the expensive half to rebuild.
