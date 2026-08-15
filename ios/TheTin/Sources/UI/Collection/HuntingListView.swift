import SwiftUI

/// Cards you are actively buying: a budget, a condition floor, and one tap to a precise eBay
/// search. Deliberately a list, not a grid — every row carries two numbers and a button, and a
/// 110pt tile can't hold that. A hunt runs until you switch it off; there is no expiry.
struct HuntingListView: View {
    let store: CatalogStore
    let wants: WantsModel

    @State private var editing: CardRecord?
    /// `printed_total` per set, for the collector denominator in the eBay query.
    /// `store.printedTotal` is a per-call DB hit, so it is cached per set — same reason
    /// `CandidateIndex` caches it at init rather than asking per card.
    @State private var printedTotalBySet: [String: Int] = [:]

    var body: some View {
        // Computed directly per body pass rather than cached (contrast `WishlistCatalog` in
        // WantedCardsView): this screen has no `.searchable` keystroke driving re-renders, so
        // there's no hot path to protect, and a cache here would risk showing a card whose
        // hunt was just switched on elsewhere without its price/set loaded yet.
        let ids = wants.entries.filter { $0.value.hunt != nil }.map(\.key)
        let cards = (try? store.cards(ids: ids)) ?? []
        // compactMapValues: a null raw_usd (EUR/graded only) is treated as unpriced, not $0.
        let rawUsd = ((try? store.prices(cardIds: ids)) ?? [:]).compactMapValues(\.rawUsd)
        let setsById = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0) })
        let hunting = WishlistGrid.huntSorted(cards: cards, entries: wants.entries, prices: rawUsd)

        Group {
            if hunting.isEmpty { empty } else { list(hunting, rawUsd: rawUsd, setsById: setsById) }
        }
        // Fills the denominator cache for whichever sets are on the hunt. The id is the set
        // list, so hunting a card from a new set refetches and nothing else does.
        .task(id: cards.map(\.setId).sorted()) {
            for setId in Set(cards.map(\.setId)) where printedTotalBySet[setId] == nil {
                if let total = try? store.printedTotal(setId: setId) {
                    printedTotalBySet[setId] = total
                }
            }
        }
        .sheet(item: $editing) { card in
            WishlistEditSheet(card: card, price: rawUsd[card.id], wants: wants)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing on the hunt", systemImage: "binoculars")
        } description: {
            Text("Switch on Hunting for a wishlist card you're actually buying, and it shows up here with a one-tap search.")
        }
    }

    private func list(_ hunting: [CardRecord], rawUsd: [String: Double],
                      setsById: [String: SetRecord]) -> some View {
        List {
            ForEach(hunting) { card in
                HuntRow(card: card, entry: wants.entry(card.id),
                        setName: setsById[card.setId]?.name,
                        printedTotal: printedTotalBySet[card.setId],
                        marketUsd: rawUsd[card.id])
                    .contentShape(Rectangle())
                    .onTapGesture { editing = card }
                    // `.onTapGesture` alone is silent to VoiceOver — a `Button` wrapping a row that
                    // itself contains a `Link` (the eBay button) is the awkward alternative, so the
                    // tap gesture stays and picks up the traits/action a real control would carry.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { editing = card }
            }
            // Moved here from `WatchingView`'s hunting footer, which is gone — this is the screen
            // that owns hunts, so it is where how-a-hunt-reaches-you belongs.
            //
            // ⚠️ "once a day" is load-bearing and verified: eBay's saved-search alert is a daily
            // email, there is no faster free route, and no copy may imply otherwise. `HuntRow`
            // deliberately says nothing about speed at all; this is the only place that explains
            // the mechanism, so it must not be dropped again.
            Section {} footer: {
                Text("Save the search in eBay and it'll keep an eye out — eBay emails once a day.")
            }
        }
        .listStyle(.plain)
    }
}
