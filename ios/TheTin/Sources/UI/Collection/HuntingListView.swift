import SwiftUI

/// Cards you are actively buying: a budget, a condition floor, a deadline, and one tap to a
/// precise eBay search. Deliberately a list, not a grid — every row carries three numbers
/// and a button, and a 110pt tile can't hold that.
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
        let ids = wants.entries.filter { $0.value.hunt?.isActive == true }.map(\.key)
        let cards = (try? store.cards(ids: ids)) ?? []
        // compactMapValues: a null raw_usd (EUR/graded only) is treated as unpriced, not $0.
        let rawUsd = ((try? store.prices(cardIds: ids)) ?? [:]).compactMapValues(\.rawUsd)
        let setsById = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0) })
        let hunting = WishlistGrid.huntSorted(cards: cards, entries: wants.entries, prices: rawUsd)

        Group {
            if hunting.isEmpty { empty } else { list(hunting, rawUsd: rawUsd, setsById: setsById) }
        }
        .navigationTitle("Hunting")
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
        List(hunting) { card in
            row(card, rawUsd: rawUsd, setsById: setsById)
                .contentShape(Rectangle())
                .onTapGesture { editing = card }
                // `.onTapGesture` alone is silent to VoiceOver — a `Button` wrapping a row that
                // itself contains a `Link` (the eBay button) is the awkward alternative, so the
                // tap gesture stays and picks up the traits/action a real control would carry.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { editing = card }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private func row(_ card: CardRecord, rawUsd: [String: Double],
                                  setsById: [String: SetRecord]) -> some View {
        let entry = wants.entry(card.id)
        let target = entry?.targetUsd
        let market = rawUsd[card.id]
        HStack(alignment: .top, spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name).font(.headline).lineLimit(2)
                if let market, let target {
                    HStack(spacing: 4) {
                        Text(market, format: .currency(code: "USD"))
                            .foregroundStyle(market <= target ? .green : .primary)
                        Text("· budget \(target, format: .currency(code: "USD"))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                if let hunt = entry?.hunt {
                    Text("\(Hunt.daysLeftLabel(hunt.daysLeft()))  ·  \(hunt.minCondition.floorLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = Self.huntURL(card: card, entry: entry,
                                          setName: setsById[card.setId]?.name,
                                          printedTotal: printedTotalBySet[card.setId],
                                          marketUsd: market) {
                    Link(destination: url) {
                        Label("Find one on eBay", systemImage: "magnifyingglass")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                    Text("Save this search in eBay to get notified.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The eBay hunt URL for one row. Static and value-only — no store, no view state — so the
    /// wiring is testable without a view host. The denominator is the highest-value token in
    /// the query and reached production as `nil` once already; it needs a test that can fail.
    static func huntURL(card: CardRecord, entry: WantEntry?, setName: String?,
                        printedTotal: Int?, marketUsd: Double? = nil) -> URL? {
        guard entry?.hunt != nil else { return nil }
        return MarketplaceLinks.ebayHunt(
            name: card.name,
            setName: setName,
            number: card.number,
            total: MarketplaceLinks.denominator(number: card.number, printedTotal: printedTotal),
            maxUsd: entry?.targetUsd,
            marketUsd: marketUsd)
    }
}
