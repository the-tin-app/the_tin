import Foundation

/// Spec §5.2: group value = Σ(qty × latest price for the entry's grade, falling back to raw).
enum GroupStats {
    /// Unit price for one card given what the user saved about it — shared by owned entries
    /// (`entryValue`) and scan-review drafts (which aren't `CollectionEntry`s yet). Graded uses the
    /// per-card PSA column (no per-printing graded data). Raw: a played condition uses that
    /// condition's market price (`price_by_condition`), an NM/unspecified condition uses the owned
    /// printing's market price (`price_by_variant`), and everything falls back to `raw_usd` (then NM)
    /// when the specific price is missing.
    static func unitPrice(grade: Grade? = nil, condition: CardCondition? = nil,
                          variant: CardVariant? = nil, price: PriceRecord?,
                          variants: [VariantPrice] = [], conditions: [ConditionPrice] = []) -> Double? {
        if grade != nil { return price?.value(for: grade) }
        if let condition, condition != .nm,
           let cp = conditions.first(where: { $0.condition == condition.catalog })?.usd {
            // ponytail: condition prices are card-level (no condition×printing data), so a played
            // holo uses the base condition price; scale by printing premium if that data ever ships.
            return cp
        }
        if let vp = variant?.price(in: variants) { return vp }
        return price?.rawUsd ?? conditions.first(where: { $0.condition == .nearMint })?.usd
    }

    /// Spec §5.2: entry value = qty × unit price for the entry's grade/condition/printing.
    static func entryValue(_ entry: CollectionEntry, price: PriceRecord?,
                           variants: [VariantPrice] = [],
                           conditions: [ConditionPrice] = []) -> Double? {
        guard let unit = unitPrice(grade: entry.gradeValue, condition: entry.conditionValue,
                                   variant: entry.variantValue, price: price,
                                   variants: variants, conditions: conditions) else { return nil }
        return unit * Double(entry.qty)
    }

    /// Whether the entry's *recorded* condition/grade actually has its own price row — distinct
    /// from `unitPrice`/`entryValue`, which keep estimating (fallback to printing → raw → NM) even
    /// when the exact condition price is missing, because the aggregate total is meant to be a
    /// best-effort estimate (spec §5.2). A DMG copy with no `price_by_condition` row should read
    /// as unpriced for display/counting — not silently show the NM/raw estimate as if it were exact.
    static func isPricedExactly(_ entry: CollectionEntry, price: PriceRecord?,
                                variants: [VariantPrice] = [], conditions: [ConditionPrice] = []) -> Bool {
        guard entryValue(entry, price: price, variants: variants, conditions: conditions) != nil else { return false }
        guard let condition = entry.conditionValue, condition != .nm else { return true }
        return conditions.contains { $0.condition == condition.catalog }
    }

    /// The aggregate total is a best-effort ESTIMATE (spec §5.2): every entry contributes its
    /// fallback-chain value, so the tin header agrees with the portfolio series (which scales the
    /// same estimates). Only `pricedCards` is gated on exactness — an entry can be estimated in
    /// the total yet display as unpriced. Counts are PHYSICAL cards (Σ qty), matching `cardCount`,
    /// so "27 cards · 26 of 27 priced" never mixes units.
    static func totalValue(entries: [CollectionEntry], prices: [String: PriceRecord],
                           variantsByCard: [String: [VariantPrice]] = [:],
                           conditionsByCard: [String: [ConditionPrice]] = [:])
        -> (total: Double, pricedCards: Int, totalCards: Int) {
        var total = 0.0
        var priced = 0
        for entry in entries {
            let variants = variantsByCard[entry.cardId] ?? []
            let conditions = conditionsByCard[entry.cardId] ?? []
            guard let value = entryValue(entry, price: prices[entry.cardId],
                                         variants: variants, conditions: conditions) else { continue }
            total += value
            if isPricedExactly(entry, price: prices[entry.cardId], variants: variants, conditions: conditions) {
                priced += entry.qty
            }
        }
        return (total, priced, entries.cardCount)
    }

    static func sortedByValueDescending(entries: [CollectionEntry], prices: [String: PriceRecord],
                                        variantsByCard: [String: [VariantPrice]] = [:],
                                        conditionsByCard: [String: [ConditionPrice]] = [:]) -> [CollectionEntry] {
        entries.sorted {
            (entryValue($0, price: prices[$0.cardId], variants: variantsByCard[$0.cardId] ?? [],
                        conditions: conditionsByCard[$0.cardId] ?? []) ?? -1) >
            (entryValue($1, price: prices[$1.cardId], variants: variantsByCard[$1.cardId] ?? [],
                        conditions: conditionsByCard[$1.cardId] ?? []) ?? -1)
        }
    }

    /// Spec §5.2: completion = owned distinct numbers / set total.
    static func setCompletion(entries: [CollectionEntry], setCards: [CardRecord],
                              setTotal: Int) -> (owned: Int, total: Int) {
        let numberByCardId = Dictionary(uniqueKeysWithValues: setCards.map { ($0.id, $0.number) })
        let ownedNumbers = Set(entries.compactMap { numberByCardId[$0.cardId] })
        return (min(ownedNumbers.count, setTotal), setTotal)
    }
}

extension Array where Element == CollectionEntry {
    /// Physical card count = Σ qty (an entry with qty 3 is 3 cards, not 1).
    var cardCount: Int { reduce(0) { $0 + $1.qty } }
}
