import SwiftUI

/// Cards you are actively buying: a budget, a condition floor, a deadline, and one tap to a
/// precise eBay search. Deliberately a list, not a grid — every row carries three numbers
/// and a button, and a 110pt tile can't hold that.
struct HuntingListView: View {
    let store: CatalogStore
    let wants: WantsModel

    @State private var editing: CardRecord?

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
                    Text("\(daysLeft(hunt))  ·  \(floorLabel(hunt.minCondition))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = huntURL(card, entry: entry, setsById: setsById) {
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

    /// Whole days remaining, rounded up — "0 days left" on a hunt that still has hours to
    /// run reads as expired.
    private func daysLeft(_ hunt: Hunt) -> String {
        let days = max(0, Int((hunt.until.timeIntervalSinceNow / 86_400).rounded(.up)))
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    private func floorLabel(_ c: CardCondition) -> String {
        switch c {
        case .hp: return "Anything but DMG"
        case .lp: return "LP or better"
        case .nm: return "NM only"
        case .mp, .dmg: return c.rawValue
        }
    }

    private func huntURL(_ card: CardRecord, entry: WantEntry?,
                         setsById: [String: SetRecord]) -> URL? {
        guard entry?.hunt != nil else { return nil }
        return MarketplaceLinks.ebayHunt(name: card.name,
                                         setName: setsById[card.setId]?.name,
                                         number: card.number,
                                         total: nil,
                                         maxUsd: entry?.targetUsd)
    }
}
