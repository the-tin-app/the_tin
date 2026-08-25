import Foundation

/// What one pocket is showing.
enum SlotState: Equatable {
    /// You own a copy of the planned card, in this binder's own divider.
    case filled
    /// Planned but not here. `elsewhere` is the `groupId` of a divider that does hold one, so the
    /// binder can say "in Vintage Holos" instead of sending you shopping for a card you own.
    case needed(elsewhere: String?)
    /// Nothing is planned for this pocket.
    case empty
}

/// Derives every pocket's state from the layout and the collection.
///
/// ⚠️ **Nothing about fullness is stored, and that is the design.** A stored `entryId` link would
/// dangle on `isSameCopy` folding two rows into a ×2 during a bulk move, on a sell, on a CSV
/// "Replace collection", and on a restore — the same silent per-copy destruction that `photos` and
/// `centering` each had to be written into `hasAcquisitionDetail` to prevent. Deriving from
/// `(groupId, cardId, variant)` survives all four with no repair code, which is `SetGoalsModel`'s
/// doctrine one level down: store the goal, derive the gap, and it is correct forever.
enum BinderFill {
    static func states(layout: BinderLayout, entries: [CollectionEntry]) -> [[SlotState]] {
        // cardId → the printings owned IN this binder, with quantities left to spend.
        var budget: [String: [(variant: String?, qty: Int)]] = [:]
        // cardId → a divider that holds one, for anything not in this binder.
        var elsewhere: [String: String] = [:]

        for e in entries where e.qty > 0 {
            if e.groupId == layout.groupId {
                let v = e.variantValue?.rawValue
                var buckets = budget[e.cardId] ?? []
                if let i = buckets.firstIndex(where: { $0.variant == v }) {
                    buckets[i].qty += e.qty
                } else {
                    buckets.append((variant: v, qty: e.qty))
                }
                budget[e.cardId] = buckets
            } else if elsewhere[e.cardId] == nil {
                elsewhere[e.cardId] = e.groupId
            }
        }

        return layout.pages.map { page in
            page.slots.map { slot in
                guard let slot else { return .empty }
                if spend(&budget, slot) { return .filled }
                return .needed(elsewhere: elsewhere[slot.cardId])
            }
        }
    }

    /// Take one copy out of the budget for `slot`, if there is one. A slot naming a printing takes
    /// only that printing; a slot naming none takes whatever is left, so one physical copy is
    /// still spent exactly once.
    private static func spend(_ budget: inout [String: [(variant: String?, qty: Int)]],
                              _ slot: PlannedCard) -> Bool {
        guard var buckets = budget[slot.cardId] else { return false }
        let hit: Int? = slot.variant.map { wanted in
            buckets.firstIndex { $0.variant == wanted && $0.qty > 0 }
        } ?? buckets.firstIndex { $0.qty > 0 }
        guard let i = hit else { return false }
        buckets[i].qty -= 1
        budget[slot.cardId] = buckets
        return true
    }
}
