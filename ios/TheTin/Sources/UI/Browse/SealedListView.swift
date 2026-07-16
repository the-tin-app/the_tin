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

/// Global browse of every sealed product (booster boxes, ETBs, packs, tins) as an image grid.
/// Empty until the pipeline starts populating `sealed_product`, so it shows a placeholder until then.
struct SealedListView: View {
    let store: CatalogStore
    @State private var products: [SealedProduct]
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    init(store: CatalogStore) {
        self.store = store
        _products = State(initialValue: (try? store.allSealedProducts()) ?? [])
    }

    private var filtered: [SealedProduct] {
        guard !query.isEmpty else { return products }
        return products.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if products.isEmpty {
                ContentUnavailableView("No sealed products yet",
                                       systemImage: "shippingbox",
                                       description: Text("Box and pack prices arrive with an upcoming catalog update."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { SealedCard(product: $0) }
                    }
                    .padding()
                }
                .searchable(text: $query, prompt: "Search sealed products")
            }
        }
        .navigationTitle("Sealed")
        .navigationBarTitleDisplayMode(.inline)
    }
}
