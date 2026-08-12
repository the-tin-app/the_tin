import SwiftUI

/// Long-press quick actions for any card tile or page: toggle Wanted, or save a copy to the tin.
/// The save sheet lives here rather than at each call site so every grid gets the same form —
/// with the card's real printings/conditions loaded from the catalog (not `CollectionModel`,
/// which only caches the cards you already own, so a brand-new card would get a price-less,
/// unfiltered printing picker).
struct CardQuickActions: ViewModifier {
    let card: CardRecord
    var wants: WantsModel?
    var collection: CollectionModel?
    var store: CatalogStore?
    @State private var saving = false
    /// The second door into hunting — see `WishlistEditSheet.armHunt`.
    @State private var hunting = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let wants {
                    Button {
                        wants.toggle(card.id)
                    } label: {
                        Label(wants.isWanted(card.id) ? "Remove from Wishlist" : "Add to Wishlist",
                              systemImage: wants.isWanted(card.id) ? "heart.slash" : "heart")
                    }
                    // Only for a card already hearted: `WantsModel.update` no-ops on a card that
                    // isn't wanted, so this would be a button that silently does nothing.
                    if wants.isWanted(card.id) {
                        Button {
                            hunting = true
                        } label: {
                            Label(wants.entry(card.id)?.hunt == nil
                                  ? "Hunt this card…" : "Edit hunt…",
                                  systemImage: "binoculars")
                        }
                    }
                }
                if collection != nil {
                    Button {
                        saving = true
                    } label: {
                        Label("Save to tin…", systemImage: "plus.square.on.square")
                    }
                }
            }
            .sheet(isPresented: $saving) { saveSheet }
            .sheet(isPresented: $hunting) { huntSheet }
    }

    @ViewBuilder private var saveSheet: some View {
        if let collection {
            NavigationStack {
                EntryFormView(card: card, groups: collection.groups, existing: nil,
                              variants: (try? store?.variantPrices(cardId: card.id)) ?? [],
                              conditions: (try? store?.conditionPrices(cardId: card.id)) ?? [],
                              matrix: (try? store?.matrixPrices(cardId: card.id)) ?? [],
                              onCreateGroup: { await collection.createGroup(name: $0) }) { entry in
                    await collection.saveEntry(entry)
                }
            }
        }
    }

    @ViewBuilder private var huntSheet: some View {
        if let wants {
            WishlistEditSheet(
                card: card,
                price: (try? store?.prices(cardIds: [card.id]))?[card.id]?.rawUsd,
                wants: wants,
                armHunt: true)
        }
    }
}

extension View {
    func cardQuickActions(card: CardRecord, wants: WantsModel?,
                          collection: CollectionModel? = nil,
                          store: CatalogStore? = nil) -> some View {
        modifier(CardQuickActions(card: card, wants: wants, collection: collection, store: store))
    }
}
