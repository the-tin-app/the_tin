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
    /// Present to offer "Add to tin". nil in contexts with no collection (previews) — the tile
    /// then reads exactly as it did before sealed became ownable.
    var collection: CollectionModel? = nil
    @State private var adding = false

    /// Boxes of this product already in the tin. Reading `collection.sealed` here is what keeps
    /// the badge live — `CollectionModel` is `@Observable`, so saving from the sheet updates the
    /// tile behind it without this view holding any state of its own.
    private var owned: Int { collection?.sealed.boxCount(productId: product.tcgplayerId) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: product.imageURL)
                .aspectRatio(1, contentMode: .fit) // sealed boxes are roughly square, not card-shaped
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Same badge the card tiles carry, in the same corner — with the count, because
                // "do I own this box" and "how many" are one question for sealed.
                .overlay(alignment: .topTrailing) {
                    if owned > 0 { CardBadges(owned: true, wanted: false, count: owned) }
                }
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
            // The only way into the tin in v1. Sealed isn't in catalog search or the scanner, so
            // the per-set section is the single discovery surface and this is where the door goes.
            if collection != nil {
                Button { adding = true } label: {
                    Label("Add to tin", systemImage: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .padding(.top, 2)
            }
        }
        .contextMenu {
            if collection != nil {
                Button { adding = true } label: {
                    Label("Add to tin…", systemImage: "plus.square.on.square")
                }
            }
        }
        .sheet(isPresented: $adding) {
            if let collection {
                NavigationStack {
                    SealedEntryFormView(product: product) { await collection.saveSealed($0) }
                }
            }
        }
    }
}

// The global "Sealed" browse segment was deleted here (2026-07-25). It was a grid of 2,510 real,
// priced products with no tap, no heart, no add and no navigation — the app's purest dead end,
// holding a quarter of the width of its only catalog door, permanently.
//
// The reason given at the time was that sealed products were not ownable — `CollectionEntry` is
// cardId-keyed, and `isSameCopy`, the CSV round-trip, the backup schema and the share links all
// inherit that. That is no longer true: `SealedEntry` was added rather than bent out of
// `CollectionEntry`, and this tile is now the door into the tin. The segment stays deleted anyway
// — the per-set section is the discovery surface a sealed product belongs on, because it reads as
// context for a set you're already looking at.
//
// `CatalogStore.allSealedProducts()` is kept and still tested — it's the query any future global
// surface starts from, and deleting it would be the expensive half to rebuild.
