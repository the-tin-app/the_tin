import SwiftUI

/// One hunted card, rendered identically wherever hunting appears — the Watching screen's
/// leading section and Wanted → Hunting. Extracted so the two surfaces cannot drift: they are
/// two entry points to one list, not two lists.
///
/// No "save this search" coaching caption. Verified against live eBay on 2026-08-01: opening
/// this link launches the eBay app with the category, Buy It Now and price band intact, and
/// eBay itself offers to save the search at exactly that moment. Saying it ourselves is noise.
///
/// ⚠️ The button says "Find one on eBay" and nothing here implies speed. eBay's saved-search
/// alert is a DAILY email — there is no faster free route, and no copy may suggest otherwise.
/// See `docs/superpowers/specs/2026-08-01-price-alert-delivery-design.md` §8.3.
struct HuntRow: View {
    let card: CardRecord
    let entry: WantEntry?
    let setName: String?
    let printedTotal: Int?
    let marketUsd: Double?
    /// 7-day change. `nil` on the casual tier, where `price_delta` ships with zero rows.
    var delta7d: Double? = nil

    var body: some View {
        let target = entry?.targetUsd
        HStack(alignment: .top, spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name).font(.headline).lineLimit(2)
                if let marketUsd, let target {
                    HStack(spacing: 4) {
                        Text(marketUsd, format: .currency(code: "USD"))
                            .foregroundStyle(marketUsd <= target ? Color.statusPositive : .primary)
                        Text("· budget \(target, format: .currency(code: "USD"))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                if let hunt = entry?.hunt {
                    HStack(spacing: 6) {
                        Text(hunt.minCondition.floorLabel)
                        if let delta7d {
                            let d = Self.delta(delta7d)
                            Text(d.text)
                                .foregroundStyle(d.isFlat ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(delta7d < 0 ? Color.statusPositive
                                                                             : Color.statusNegative))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let url = Self.huntURL(card: card, entry: entry, setName: setName,
                                          printedTotal: printedTotal, marketUsd: marketUsd) {
                    Link(destination: url) {
                        Label("Find one on eBay", systemImage: "magnifyingglass")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A weekly move, and whether it rounds to nothing.
    ///
    /// ⚠️ **The flat threshold must match the DISPLAY precision.** This renders whole percent,
    /// so anything under 0.5% shows as "0%" — and an arrow plus a colour beside "0%" claims a
    /// direction the number itself denies. Shipped that way for a few hours on 2026-08-01 and
    /// read as broken on a card that had barely moved. `DeltaBadge` has the same rule with a
    /// tighter bound (0.0005) because it shows one decimal; the bound follows the format, not
    /// the other way round.
    struct Delta {
        let text: String
        /// True when the move rounds to zero at this precision — render it neutral, not green.
        let isFlat: Bool
    }

    /// "↓14% this week" / "↑3% this week" / "unchanged this week".
    static func delta(_ pct: Double) -> Delta {
        let whole = Int((abs(pct) * 100).rounded())
        guard whole > 0 else { return Delta(text: "unchanged this week", isFlat: true) }
        return Delta(text: "\(pct < 0 ? "↓" : "↑")\(whole)% this week", isFlat: false)
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
