import Foundation

/// Cover/appendix numbers for the insurance report. Pure aggregation over GroupStats — the
/// report never invents a price the app wouldn't show.
struct ReportTotals: Equatable {
    let totalValue: Double
    let pricedEntries: Int   // cover coverage note: "Valued: X of Y entries"
    let totalEntries: Int
    let totalCards: Int      // Σ qty
    let costBasis: Double    // Σ pricePaid (pricePaid is the entry TOTAL — spec-locked)
}

/// One appendix line: a divider's card count and value.
struct DividerSubtotal: Identifiable, Equatable {
    let id: String           // group id; "" = ungrouped ("No divider")
    let name: String
    let cards: Int           // Σ qty
    let value: Double
}

enum InsuranceReport {
    static func totals(entries: [CollectionEntry], prices: [String: PriceRecord],
                       variantsByCard: [String: [VariantPrice]],
                       conditionsByCard: [String: [ConditionPrice]]) -> ReportTotals {
        let v = GroupStats.totalValue(entries: entries, prices: prices,
                                      variantsByCard: variantsByCard,
                                      conditionsByCard: conditionsByCard)
        return ReportTotals(totalValue: v.total, pricedEntries: v.pricedEntries,
                            totalEntries: v.totalEntries, totalCards: entries.cardCount,
                            costBasis: entries.compactMap(\.pricePaid).reduce(0, +))
    }

    /// Per-divider subtotals in tin order; ungrouped cards last as "No divider". Empty dividers
    /// are skipped — nothing to insure.
    static func subtotals(entries: [CollectionEntry], groups: [CardGroup],
                          prices: [String: PriceRecord],
                          variantsByCard: [String: [VariantPrice]],
                          conditionsByCard: [String: [ConditionPrice]]) -> [DividerSubtotal] {
        var buckets = [(id: String, name: String)]()
        buckets.append(contentsOf: groups.map { ($0.id, $0.name) })
        buckets.append(("", "No divider"))
        return buckets.compactMap { id, name in
            let inGroup = entries.filter { $0.groupId == id }
            guard !inGroup.isEmpty else { return nil }
            let v = GroupStats.totalValue(entries: inGroup, prices: prices,
                                          variantsByCard: variantsByCard,
                                          conditionsByCard: conditionsByCard)
            return DividerSubtotal(id: id, name: name, cards: inGroup.cardCount, value: v.total)
        }
    }
}

/// One inventory-table row — everything the report prints for a collection entry. Missing
/// provenance stays nil and prints blank (honest gaps); missing prices print "—".
struct ReportRow: Identifiable, Equatable {
    let id: String            // entry id
    let card: CardRecord?     // nil when the catalog no longer resolves the id (row still prints)
    let name: String          // card name, or the raw card id when unresolved
    let setLine: String       // "Evolving Skies · #215"; "" when unresolved
    let detail: String        // "Holo · LP · PSA 9" — printing/condition/grade, only what's set
    let qty: Int
    let acquiredAt: Date?
    let acquiredFrom: String?
    let pricePaid: Double?    // entry total (spec-locked)
    let currentValue: Double? // entry total — GroupStats.entryValue, qty-inclusive
}

extension InsuranceReport {
    /// All entries → table rows, current-value descending (unpriced last).
    static func rows(entries: [CollectionEntry], cards: [String: CardRecord],
                     setNames: [String: String], prices: [String: PriceRecord],
                     variantsByCard: [String: [VariantPrice]],
                     conditionsByCard: [String: [ConditionPrice]]) -> [ReportRow] {
        let sorted = GroupStats.sortedByValueDescending(entries: entries, prices: prices,
                                                        variantsByCard: variantsByCard,
                                                        conditionsByCard: conditionsByCard)
        return sorted.map { entry in
            let card = cards[entry.cardId]
            let detail = [entry.variantValue?.label, entry.condition, entry.gradeValue?.label]
                .compactMap { $0 }.joined(separator: " · ")
            return ReportRow(
                id: entry.id, card: card,
                name: card?.name ?? entry.cardId,
                setLine: card.map { "\(setNames[$0.setId] ?? $0.setId) · #\($0.number)" } ?? "",
                detail: detail, qty: entry.qty,
                acquiredAt: entry.acquiredAt, acquiredFrom: entry.acquiredFrom,
                pricePaid: entry.pricePaid,
                currentValue: GroupStats.entryValue(entry, price: prices[entry.cardId],
                                                    variants: variantsByCard[entry.cardId] ?? [],
                                                    conditions: conditionsByCard[entry.cardId] ?? []))
        }
    }
}
