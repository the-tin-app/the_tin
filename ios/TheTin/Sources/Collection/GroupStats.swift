import Foundation

/// Spec §5.2: group value = Σ(qty × latest price for the entry's grade, falling back to raw).
enum GroupStats {
    /// Unit price for one card given what the user saved about it — shared by owned entries
    /// (`entryValue`) and scan-review drafts. FIRST rung: the exact printing×condition (or
    /// printing×grade) cell when the catalog has it. Then the pre-matrix chain unchanged:
    /// graded → psa column; played condition → card-level condition price; NM/unspecified →
    /// owned printing's market; then raw_usd, then NM.
    static func unitPrice(grade: Grade? = nil, condition: CardCondition? = nil,
                          variant: CardVariant? = nil, price: PriceRecord?,
                          variants: [VariantPrice] = [], conditions: [ConditionPrice] = [],
                          matrix: [MatrixPrice] = [],
                          gradedByPrinting: [GradedPrintingPrice] = []) -> Double? {
        if let grade {
            if let variant,
               let gp = gradedByPrinting.first(where: { $0.grade == grade.rawValue && variant.matches(printing: $0.printing) }) {
                return gp.usd
            }
            return price?.value(for: grade)
        }
        if let condition, let variant,
           let cell = matrix.first(where: { $0.condition == condition.catalog && variant.matches(printing: $0.printing) }) {
            return cell.usd
        }
        if let condition, condition != .nm,
           let cp = conditions.first(where: { $0.condition == condition.catalog })?.usd {
            return cp
        }
        if let vp = variant?.price(in: variants) { return vp }
        return price?.rawUsd ?? conditions.first(where: { $0.condition == .nearMint })?.usd
    }

    /// The price-change (`price_delta`) row that matches what an owned entry actually is — the
    /// change counterpart to `unitPrice`. MUST mirror `unitPrice`'s rung order so the % change
    /// tracks the SAME price the value uses: graded → PSA grade; else printing×condition matrix →
    /// card-level condition → printing → raw. (Bug 2026-07-21: this ladder had silently dropped the
    /// matrix + condition rungs, so every played/ungraded copy showed the raw market change.)
    static func unitDelta(_ entry: CollectionEntry, records: [DeltaRecord]) -> DeltaRecord? {
        if let grade = entry.gradeValue {
            return records.first { $0.kind == .psa && $0.key == String(grade.numeric) }
        }
        if let condition = entry.conditionValue, let variant = entry.variantValue,
           let matrix = records.first(where: {
               $0.kind == .matrix && matrixDeltaKey($0.key, matches: variant, condition: condition) }) {
            return matrix
        }
        if let condition = entry.conditionValue, condition != .nm,
           let cond = records.first(where: { $0.kind == .condition && $0.key == condition.catalog.rawValue }) {
            return cond
        }
        if let variant = entry.variantValue,
           let printing = records.first(where: { $0.kind == .printing && variant.matches(printing: $0.key) }) {
            return printing
        }
        return records.first { $0.kind == .raw }
    }

    /// A `.matrix` delta key is "<printing>|<condition rawValue>" (publish-tiers.ts). Condition
    /// rawValues never contain "|", so split on the LAST bar; match the printing half to the
    /// entry's variant and the condition half to its condition.
    private static func matrixDeltaKey(_ key: String, matches variant: CardVariant,
                                       condition: CardCondition) -> Bool {
        guard let bar = key.lastIndex(of: "|") else { return false }
        return String(key[key.index(after: bar)...]) == condition.catalog.rawValue
            && variant.matches(printing: String(key[..<bar]))
    }

    /// Spec §5.2: entry value = qty × unit price for the entry's grade/condition/printing.
    static func entryValue(_ entry: CollectionEntry, price: PriceRecord?,
                           variants: [VariantPrice] = [],
                           conditions: [ConditionPrice] = [],
                           matrix: [MatrixPrice] = [],
                           gradedByPrinting: [GradedPrintingPrice] = []) -> Double? {
        guard let unit = unitPrice(grade: entry.gradeValue, condition: entry.conditionValue,
                                   variant: entry.variantValue, price: price,
                                   variants: variants, conditions: conditions,
                                   matrix: matrix, gradedByPrinting: gradedByPrinting) else { return nil }
        return unit * Double(entry.qty)
    }

    /// Whether the entry's *recorded* condition/grade actually has its own price row — distinct
    /// from `unitPrice`/`entryValue`, which keep estimating (fallback to printing → raw → NM) even
    /// when the exact condition price is missing, because the aggregate total is meant to be a
    /// best-effort estimate (spec §5.2). A DMG copy with no `price_by_condition` row should read
    /// as unpriced for display/counting — not silently show the NM/raw estimate as if it were exact.
    /// A matrix-priced entry (exact printing×condition cell) also counts as exact.
    static func isPricedExactly(_ entry: CollectionEntry, price: PriceRecord?,
                                variants: [VariantPrice] = [], conditions: [ConditionPrice] = [],
                                matrix: [MatrixPrice] = [],
                                gradedByPrinting: [GradedPrintingPrice] = []) -> Bool {
        guard entryValue(entry, price: price, variants: variants, conditions: conditions,
                         matrix: matrix, gradedByPrinting: gradedByPrinting) != nil else { return false }
        guard let condition = entry.conditionValue, condition != .nm else { return true }
        if let variant = entry.variantValue,
           matrix.contains(where: { $0.condition == condition.catalog && variant.matches(printing: $0.printing) }) {
            return true
        }
        return conditions.contains { $0.condition == condition.catalog }
    }

    /// The aggregate total is a best-effort ESTIMATE (spec §5.2): every entry contributes its
    /// fallback-chain value, so the tin header agrees with the portfolio series (which scales the
    /// same estimates). Only `pricedCards` is gated on exactness — an entry can be estimated in
    /// the total yet display as unpriced. Counts are PHYSICAL cards (Σ qty), matching `cardCount`,
    /// so "27 cards · 26 of 27 priced" never mixes units.
    static func totalValue(entries: [CollectionEntry], prices: [String: PriceRecord],
                           variantsByCard: [String: [VariantPrice]] = [:],
                           conditionsByCard: [String: [ConditionPrice]] = [:],
                           matrixByCard: [String: [MatrixPrice]] = [:],
                           gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:])
        -> (total: Double, pricedCards: Int, totalCards: Int) {
        var total = 0.0
        var priced = 0
        for entry in entries {
            let variants = variantsByCard[entry.cardId] ?? []
            let conditions = conditionsByCard[entry.cardId] ?? []
            let matrix = matrixByCard[entry.cardId] ?? []
            let gradedByPrinting = gradedByPrintingByCard[entry.cardId] ?? []
            guard let value = entryValue(entry, price: prices[entry.cardId],
                                         variants: variants, conditions: conditions,
                                         matrix: matrix, gradedByPrinting: gradedByPrinting) else { continue }
            total += value
            if isPricedExactly(entry, price: prices[entry.cardId], variants: variants, conditions: conditions,
                               matrix: matrix, gradedByPrinting: gradedByPrinting) {
                priced += entry.qty
            }
        }
        return (total, priced, entries.cardCount)
    }

    static func sortedByValueDescending(entries: [CollectionEntry], prices: [String: PriceRecord],
                                        variantsByCard: [String: [VariantPrice]] = [:],
                                        conditionsByCard: [String: [ConditionPrice]] = [:],
                                        matrixByCard: [String: [MatrixPrice]] = [:],
                                        gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]) -> [CollectionEntry] {
        entries.sorted {
            (entryValue($0, price: prices[$0.cardId], variants: variantsByCard[$0.cardId] ?? [],
                        conditions: conditionsByCard[$0.cardId] ?? [], matrix: matrixByCard[$0.cardId] ?? [],
                        gradedByPrinting: gradedByPrintingByCard[$0.cardId] ?? []) ?? -1) >
            (entryValue($1, price: prices[$1.cardId], variants: variantsByCard[$1.cardId] ?? [],
                        conditions: conditionsByCard[$1.cardId] ?? [], matrix: matrixByCard[$1.cardId] ?? [],
                        gradedByPrinting: gradedByPrintingByCard[$1.cardId] ?? []) ?? -1)
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
