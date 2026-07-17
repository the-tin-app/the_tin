import SwiftUI
import UniformTypeIdentifiers

/// Grid of the user's wanted cards, resolved from the offline catalog by id.
/// Reached only via `WantedRoute` (never a `String`), so it cannot collide with the
/// real-group `.navigationDestination(for: String.self)` on the Collection stack.
struct WantedCardsView: View {
    let store: CatalogStore
    let wants: WantsModel
    var collection: CollectionModel? = nil
    @State private var printRequest: PrintSheetRequest?
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
    @State private var exportDoc: CSVDocument?

    private var cards: [CardRecord] {
        let ids = Array(wants.wanted)
        return ((try? store.cards(ids: ids)) ?? []).sorted { $0.name < $1.name }
    }
    private var prices: [String: PriceRecord] { (try? store.prices(cardIds: cards.map(\.id))) ?? [:] }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Your wishlist is empty")
                    } icon: {
                        Image(systemName: "heart").foregroundStyle(.secondary)
                    }
                } description: {
                    Text("Tap the heart on any card to start hunting for it here.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards) { card in
                            NavigationLink(value: CardID(raw: card.id)) {
                                VStack(spacing: 4) {
                                    CardImageView(card: card, quality: "low")
                                    Text(card.name).font(.caption).lineLimit(1)
                                    if let usd = prices[card.id]?.rawUsd {
                                        Text(usd, format: .currency(code: "USD")).font(.caption2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding()
                }
            }
        }
        .navigationTitle("Wishlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                let sets = Dictionary(uniqueKeysWithValues: ((try? store.sets()) ?? []).map { ($0.id, $0) })
                exportDoc = CSVDocument(data: CollectionCSV.exportWishlist(cards: cards, sets: sets,
                                                                           prices: prices))
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Export wishlist (CSV)")
            .disabled(cards.isEmpty)
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil },
                                           set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .commaSeparatedText,
                      defaultFilename: CollectionCSV.filename("the-tin-wishlist")) { _ in
            exportDoc = nil
        }
        .toolbar {
            Button { printRequest = PrintSheet.wantRequest(cards: cards, store: store) }
                label: { Label("Print want list…", systemImage: "printer") }
                .disabled(cards.isEmpty)
        }
        .printSheetFlow($printRequest)
    }
}
