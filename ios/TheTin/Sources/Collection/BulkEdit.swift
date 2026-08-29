import Foundation

/// One change applied to many cards at once — what "I got all of these at the same show" needs.
///
/// Every field is Optional and `nil` means **leave unchanged**, never "clear it". That asymmetry is
/// deliberate: the sheet's blank state is the one you get by opening it and touching nothing, and it
/// must be incapable of destroying data. Clearing a field stays a single-card edit.
///
/// Deliberately a plain struct with no view and no repository: the arithmetic here (how a lot price
/// divides, which rows an edit makes indistinguishable) is exactly what needs testing, and none of
/// it needs a screen to run.
struct BulkEdit: Equatable {
    /// What a typed amount means across a selection.
    ///
    /// `CollectionEntry.pricePaid` is a TOTAL for that row's quantity, so neither case is a straight
    /// assignment — `.each` multiplies by qty, `.lot` divides.
    enum Price: Equatable {
        /// "They were $5 a card." Each row gets `amount × qty`.
        case each(Double)
        /// "The whole box was $120." Split across the selection, weighted by quantity.
        case lot(Double)
    }

    var acquiredAt: Date?
    /// Blank counts as unchanged, not as "erase the source" — see the type comment.
    var acquiredFrom: String?
    var acquiredVia: AcquiredVia?
    var price: Price?
    var condition: CardCondition?
    /// Only ever one of the four finishes. A catalog print run ("Cosmos Holo") names one specific
    /// card's printing, so offering it across a mixed selection would mis-value every other card in
    /// it — the sheet's picker is limited to `CardVariant.allCases` for that reason.
    var variant: CardVariant?
    var forTrade: Bool?

    var isEmpty: Bool {
        acquiredAt == nil && acquiredFrom == nil && acquiredVia == nil && price == nil
            && condition == nil && variant == nil && forTrade == nil
    }

    /// The rows to write and the rows to delete, ready for `repository.applyEntryEdits`.
    ///
    /// Sold rows are dropped rather than edited. They're already filtered out of
    /// `CollectionModel.entries` (the only pool the selection can draw from), but a sold row is a
    /// closed record whose cost basis feeds realised P&L — rewriting one from a bulk sheet would
    /// silently restate history, so the rule is stated where it's enforced.
    func apply(to entries: [CollectionEntry]) -> (updated: [CollectionEntry], deletedIds: [String]) {
        let editable = entries.filter { !$0.isSold }
        guard !isEmpty, !editable.isEmpty else { return ([], []) }
        var out = editable
        let shares = priceShares(for: editable)
        for i in out.indices {
            if let acquiredAt { out[i].acquiredAt = acquiredAt }
            if let acquiredFrom, !acquiredFrom.isEmpty { out[i].acquiredFrom = acquiredFrom }
            if let acquiredVia { out[i].acquiredVia = acquiredVia.rawValue }
            // A graded card's condition IS its grade, which is why `EntryFormView` hides the
            // condition picker on a slab. Writing one here anyway would put "NM" on a PSA 9 —
            // a fact that can't be true — for every slab that happened to be in the selection.
            if let condition, out[i].grade == nil { out[i].condition = condition.rawValue }
            if let variant { out[i].variant = variant.rawValue }
            // nil rather than false when off, matching `EntryFormView`: an entry that was never
            // marked stays byte-identical to what it was before the field existed.
            if let forTrade { out[i].forTrade = forTrade ? true : nil }
            if let share = shares?[i] { out[i].pricePaid = share }
        }
        return fold(out)
    }

    /// How many of these rows already hold a value in a field this edit writes — the number the
    /// sheet shows before you commit, so a bulk overwrite can't be silent.
    ///
    /// Counts ROWS, not fields: one card whose date and price both get replaced is one card whose
    /// data changed, which is the thing you'd want to stop and think about.
    func overwrites(in entries: [CollectionEntry]) -> Int {
        entries.filter { !$0.isSold && replacesSomething(in: $0) }.count
    }

    private func replacesSomething(in e: CollectionEntry) -> Bool {
        if acquiredAt != nil, e.acquiredAt != nil { return true }
        if let acquiredFrom, !acquiredFrom.isEmpty, !(e.acquiredFrom ?? "").isEmpty { return true }
        if acquiredVia != nil, e.acquiredViaValue != nil { return true }
        if price != nil, e.pricePaid != nil { return true }
        // Mirrors `apply`: a slab's condition is never written, so it is never overwritten either.
        if condition != nil, e.grade == nil, e.conditionValue != nil { return true }
        if variant != nil, e.variantValue != nil { return true }
        if forTrade != nil, e.forTrade != nil { return true }
        return false
    }

    /// Each row's new `pricePaid`, keyed by its index in `entries`, or nil when this edit sets no
    /// price. Values are totals for that row's quantity, which is how the field is stored.
    private func priceShares(for entries: [CollectionEntry]) -> [Int: Double]? {
        guard let price else { return nil }
        switch price {
        case .each(let amount):
            return Dictionary(uniqueKeysWithValues:
                entries.indices.map { ($0, amount * Double(Self.units(entries[$0]))) })
        case .lot(let total):
            let cents = Int((total * 100).rounded())
            let allUnits = entries.reduce(0) { $0 + Self.units($1) }
            guard allUnits > 0 else { return nil }
            // Allocated on a running total in integer cents: each row takes the difference between
            // two floors, so the shares sum to EXACTLY the lot price. Rounding each row's own
            // `total × qty / allUnits` independently loses or invents a cent on most splits, and a
            // cost basis that doesn't add up to what you actually paid is worse than no basis.
            var out: [Int: Double] = [:]
            var seenUnits = 0, allocated = 0
            for i in entries.indices {
                seenUnits += Self.units(entries[i])
                let upTo = cents * seenUnits / allUnits
                out[i] = Double(upTo - allocated) / 100
                allocated = upTo
            }
            return out
        }
    }

    /// Fold rows this edit just made indistinguishable from each other.
    ///
    /// Bulk-setting condition, printing or the trade flag can turn two rows that were genuinely
    /// different into two identical ×1s of the same card — exactly the duplicate state
    /// `CollectionEntry.isSameCopy` exists to prevent, and at bulk scale it can happen fifteen times
    /// in one tap without you seeing any of them. `moveEntries` runs the same fold for the same
    /// reason.
    ///
    /// A price can never be lost to this: setting a price, date or source makes
    /// `hasAcquisitionDetail` true on BOTH sides, so `isSameCopy` is false and nothing folds.
    ///
    /// Scoped to the selection, not the whole tin — an edited row that comes to match some untouched
    /// row elsewhere is left alone, which is what a single-card edit through `EntryFormView` does too.
    private func fold(_ entries: [CollectionEntry]) -> (updated: [CollectionEntry], deletedIds: [String]) {
        var kept: [CollectionEntry] = []
        var deletedIds: [String] = []
        for entry in entries {
            if let i = kept.firstIndex(where: { $0.isSameCopy(as: entry) }) {
                kept[i].qty += entry.qty
                deletedIds.append(entry.id)
            } else {
                kept.append(entry)
            }
        }
        return (kept, deletedIds)
    }

    /// A row with a nonsense quantity still represents one physical card, and must not take a zero
    /// or negative share of a lot price.
    private static func units(_ e: CollectionEntry) -> Int { max(e.qty, 1) }
}
