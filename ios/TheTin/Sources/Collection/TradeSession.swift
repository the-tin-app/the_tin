import Foundation

/// One line on the table: a card, and how many copies of it are in the trade.
///
/// `entry` is a real owned row on your side and a synthetic, never-saved row on theirs — the
/// same type deliberately, so both columns price through `GroupStats` on the identical ladder.
/// A balance whose two halves are priced by different code is the one bug this screen cannot
/// afford: the whole feature is a single percentage, shown to someone across a table.
struct TradeLine: Identifiable, Equatable {
    var entry: CollectionEntry
    /// Copies of `entry` on the table. On your side this may be fewer than `entry.qty` — you keep
    /// the sharp one and trade the other three.
    var copies: Int
    var id: String { entry.id }

    /// The row as it should be VALUED: everything the source row records (printing, condition,
    /// grade), at trade quantity rather than owned quantity.
    var valued: CollectionEntry {
        var e = entry
        e.qty = copies
        return e
    }
}

/// One column of the trade. Cash folds into this side's total before the comparison, which is
/// what makes "add $20 to even it out" mean the obvious thing.
struct TradeSide: Equatable {
    var lines: [TradeLine] = []
    var cashUsd: Double = 0

    var isEmpty: Bool { lines.isEmpty && cashUsd == 0 }
    var cardCount: Int { lines.reduce(0) { $0 + $1.copies } }

    mutating func remove(id: String) { lines.removeAll { $0.id == id } }
}

/// The catalog price tables both columns are valued against, fetched for the UNION of the two
/// sides in one pass.
///
/// Your cards are already priced in `CollectionModel`; theirs never are, because you don't own
/// them. Reading the two columns from two different sources is how a balance quietly lies, so
/// this owns both and `CollectionModel` is not consulted for value at all.
struct TradePrices {
    var prices: [String: PriceRecord] = [:]
    var variantsByCard: [String: [VariantPrice]] = [:]
    var conditionsByCard: [String: [ConditionPrice]] = [:]
    var matrixByCard: [String: [MatrixPrice]] = [:]
    var gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]

    /// Total, priced-card count and card count for one side — the same tuple the tin header and
    /// the trade list already speak, so "3 of 14 cards priced" reads identically everywhere.
    /// Cash is NOT included: it is never unpriced, and folding it in here would corrupt the count.
    func value(_ side: TradeSide) -> (total: Double, pricedCards: Int, totalCards: Int) {
        GroupStats.totalValue(entries: side.lines.map(\.valued), prices: prices,
                              variantsByCard: variantsByCard, conditionsByCard: conditionsByCard,
                              matrixByCard: matrixByCard, gradedByPrintingByCard: gradedByPrintingByCard)
    }

    /// What one line is worth, for the row's own caption. nil when the recorded condition has no
    /// price of its own — display should say so rather than substitute an NM estimate.
    func lineValue(_ line: TradeLine) -> Double? {
        let e = line.valued
        let variants = variantsByCard[e.cardId] ?? []
        let conditions = conditionsByCard[e.cardId] ?? []
        let matrix = matrixByCard[e.cardId] ?? []
        let graded = gradedByPrintingByCard[e.cardId] ?? []
        guard GroupStats.isPricedExactly(e, price: prices[e.cardId], variants: variants,
                                         conditions: conditions, matrix: matrix,
                                         gradedByPrinting: graded) else { return nil }
        return GroupStats.entryValue(e, price: prices[e.cardId], variants: variants,
                                     conditions: conditions, matrix: matrix, gradedByPrinting: graded)
    }

    /// Batch-read every table for both columns at once. Mirrors `CollectionModel.reloadPrices`;
    /// each read degrades to empty independently, exactly as it does there.
    static func load(cardIds: [String], from store: CatalogStore) -> TradePrices {
        let ids = Array(Set(cardIds))
        guard !ids.isEmpty else { return TradePrices() }
        return TradePrices(prices: (try? store.prices(cardIds: ids)) ?? [:],
                           variantsByCard: (try? store.variantPrices(cardIds: ids)) ?? [:],
                           conditionsByCard: (try? store.conditionPrices(cardIds: ids)) ?? [:],
                           matrixByCard: (try? store.matrixPrices(cardIds: ids)) ?? [:],
                           gradedByPrintingByCard: (try? store.gradedPrintingPrices(cardIds: ids)) ?? [:])
    }
}

/// Who is favored, and by how much.
///
/// Favored is the side that RECEIVES more, which is the opposite of the side whose pile is
/// bigger — you hand over your column and take theirs. Getting this backwards would be a
/// confident, wrong answer given to two people who are about to act on it.
struct TradeBalance: Equatable {
    enum Favored: Equatable { case you, them, even }

    /// Value leaving your hands: your cards plus any cash you're adding.
    var yourGive: Double
    var theirGive: Double
    var favored: Favored
    /// The gap as a share of the LARGER pile, 0…1. State the denominator in the UI — a bare
    /// percentage across a table starts arguments.
    var percent: Double

    init(yourGive: Double, theirGive: Double) {
        self.yourGive = yourGive
        self.theirGive = theirGive
        let larger = max(yourGive, theirGive)
        // Two empty piles are even at 0%, not a division by zero — and an empty trade is the
        // screen's opening state, so this branch runs before anything else does.
        guard larger > 0 else { self.favored = .even; self.percent = 0; return }
        self.percent = abs(yourGive - theirGive) / larger
        self.favored = yourGive == theirGive ? .even : (theirGive > yourGive ? .you : .them)
    }
}

/// Which of your cards to put up to land near a target value.
///
/// Greedy, largest first, with one closing move: if a single unused card would land the total
/// nearer the target than stopping short does, take it.
///
/// This is deliberately NOT an optimal subset-sum. You have to justify the pile to the person
/// across the table, and "my Charizard and my Umbreon" is an argument where an optimal-but-
/// arbitrary basket of seven small cards is not. Optimality here would cost explicability, which
/// is the only currency the screen has.
enum TradeOfferBuilder {
    struct Candidate: Equatable {
        var entryId: String
        var value: Double
    }

    struct Suggestion: Equatable, Identifiable {
        /// Share of what you're taking that this offer AIMS at — 100, 95, 90.
        var percent: Int
        var entryIds: [String]
        var total: Double
        /// What the pile is actually worth as a share of what you're taking, 0…1. Below `percent`
        /// when your trade list can't reach it — the row has to say so, or it claims a share it
        /// isn't offering.
        var achieved: Double
        var id: Int { percent }
    }

    /// `taking` is the value of THEIR side — what you're receiving. Each suggestion is a set of
    /// your cards worth roughly that share of it.
    static func suggest(taking: Double, from candidates: [Candidate],
                        percents: [Int] = [100, 95, 90]) -> [Suggestion] {
        guard taking > 0, !candidates.isEmpty else { return [] }
        let ordered = candidates.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !ordered.isEmpty else { return [] }
        var out: [Suggestion] = []
        var seen = Set<String>()
        for percent in percents {
            let target = taking * Double(percent) / 100
            var picked: [Candidate] = []
            var total = 0.0
            for c in ordered where total + c.value <= target {
                picked.append(c); total += c.value
            }
            // Closing move: stopping $92 short when an unused $95 card exists is the wrong answer
            // by any reading. Take the single remaining card that lands nearest the target.
            let unused = ordered.filter { c in !picked.contains { $0.entryId == c.entryId } }
            if let closer = unused.min(by: { abs(total + $0.value - target) < abs(total + $1.value - target) }),
               abs(total + closer.value - target) < abs(total - target) {
                picked.append(closer); total += closer.value
            }
            // Rows naming the same pile are not choices. A list worth less than their side returns
            // *everything* at 100, 95 and 90 alike, which reads as three options and is one — keep
            // the first and let `achieved` say how far it actually lands.
            guard seen.insert(picked.map(\.entryId).sorted().joined(separator: "\u{1}")).inserted else { continue }
            out.append(Suggestion(percent: percent, entryIds: picked.map(\.entryId),
                                  total: total, achieved: total / taking))
        }
        return out
    }
}

/// Everything executing the trade would write, computed without touching a repository.
///
/// Split out as a value so the one destructive step in the feature is testable in full: what
/// leaves the tin, what a partially-traded stack shrinks to, and what lands in staging.
struct TradePlan: Equatable {
    /// Rows to write back. Copies that left become sold-with-no-proceeds; a stack traded in part
    /// also yields its shrunken remainder, which is a second row in this list.
    var updatedEntries: [CollectionEntry] = []
    /// Incoming cards, headed for scan staging rather than straight into a divider — nothing
    /// enters the tin unreviewed, and you are not typing condition and divider at a folding table.
    var incomingDrafts: [ScanDraft] = []
}

/// A trade in progress, across a table.
///
/// Held in memory only. A trade lasts minutes; persisting it would mean a file, a decode
/// migration and an "abandoned trade" state, for a screen you close when you walk away.
/// Nothing is written anywhere until `execute`.
///
/// There is deliberately no trade-ledger entity. `soldAt` with `soldFor: nil` already means
/// "traded away" (see `CollectionEntry.soldFor`) and `AcquiredVia.traded` already exists, so
/// both halves of the history are preserved by the model the app already has.
@MainActor @Observable
final class TradeSession {
    var yours = TradeSide()
    var theirs = TradeSide()
    private(set) var pricing = TradePrices()

    private let store: CatalogStore

    init(store: CatalogStore) { self.store = store }

    // MARK: Composition

    /// Put one copy of an owned row on your side, or bump the copies if it's already there —
    /// never past what you actually own.
    func offer(_ entry: CollectionEntry) {
        if let i = yours.lines.firstIndex(where: { $0.id == entry.id }) {
            yours.lines[i].copies = min(yours.lines[i].copies + 1, entry.qty)
        } else {
            yours.lines.append(TradeLine(entry: entry, copies: 1))
        }
        reprice()
    }

    /// Add a card from catalog search to their side. Their cards are not owned, so there is no
    /// row to reference — a synthetic one is built at the chosen condition, at the printing the
    /// scanner would guess for the same card, so the two paths price a stranger's card alike.
    func request(cardId: String, rarity: String?, condition: CardCondition = .nm, now: Date = Date()) {
        let variant = CardVariant.defaultFor(rarity: rarity)
        // Match on what a duplicate WOULD be: same card at the same condition. A second copy in a
        // different condition is a different line, because it is worth a different amount.
        if let i = theirs.lines.firstIndex(where: {
            $0.entry.cardId == cardId && $0.entry.condition == condition.rawValue
        }) {
            theirs.lines[i].copies += 1
        } else {
            let synthetic = CollectionEntry(id: UUID().uuidString, cardId: cardId, groupId: "",
                                            qty: 1, condition: condition.rawValue, grade: nil,
                                            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                                            addedAt: now, variant: variant.rawValue)
            theirs.lines.append(TradeLine(entry: synthetic, copies: 1))
        }
        reprice()
    }

    /// Fill their side from a shared trade link — the list someone posted to Discord, opened in
    /// your app instead of in a browser.
    ///
    /// The payload carries condition and quantity per card (`ShareList.Item.d`/`.q`), so their
    /// column arrives priced rather than as a list of names. A `.want` payload is refused: that
    /// link is what somebody is LOOKING for, and seeding it as "what they'll give you" would
    /// invert the entire screen.
    func seedTheirSide(from payload: ShareList.Payload, now: Date = Date()) {
        guard payload.k == .trade else { return }
        theirs.lines.removeAll()
        for item in payload.i {
            let condition = item.d.flatMap(CardCondition.init(rawValue:)) ?? .nm
            let synthetic = CollectionEntry(id: UUID().uuidString, cardId: item.c, groupId: "",
                                            qty: 1, condition: condition.rawValue, grade: nil,
                                            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                                            addedAt: now, variant: nil)
            theirs.lines.append(TradeLine(entry: synthetic, copies: max(1, item.q ?? 1)))
        }
        reprice()
    }

    /// Replace your side with the cards a suggestion names, one copy each.
    ///
    /// Applying an offer is a REPLACEMENT, not an addition — the suggestion is a whole answer to
    /// "what do I put up", and merging it into whatever was already there would produce a pile
    /// worth roughly double the target while still being labelled 95%.
    func apply(_ suggestion: TradeOfferBuilder.Suggestion, from owned: [CollectionEntry]) {
        let byId = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0) })
        yours.lines = suggestion.entryIds.compactMap { byId[$0] }.map { TradeLine(entry: $0, copies: 1) }
        reprice()
    }

    /// Offers at 100/95/90% of what their column is worth, built from cards you own.
    ///
    /// Candidates arrive already valued, by `CollectionModel`, which holds price tables for the
    /// whole tin. This session only ever loads prices for cards ON the table — asking it to value
    /// your trade list would silently score every candidate at zero.
    func suggestions(from candidates: [TradeOfferBuilder.Candidate]) -> [TradeOfferBuilder.Suggestion] {
        // Cash on their side counts: if they're adding $20 you're receiving $20 more, and an
        // offer that ignores it is short by exactly that much.
        TradeOfferBuilder.suggest(taking: theirValue.total + theirs.cashUsd, from: candidates)
    }

    func setCondition(_ condition: CardCondition, forTheirLine id: String) {
        guard let i = theirs.lines.firstIndex(where: { $0.id == id }) else { return }
        theirs.lines[i].entry.condition = condition.rawValue
        reprice()
    }

    func setCopies(_ copies: Int, forYourLine id: String) {
        guard let i = yours.lines.firstIndex(where: { $0.id == id }) else { return }
        // Never offer more copies than the row holds — the split at execute divides a real stack.
        yours.lines[i].copies = max(1, min(copies, yours.lines[i].entry.qty))
    }

    func setCopies(_ copies: Int, forTheirLine id: String) {
        guard let i = theirs.lines.firstIndex(where: { $0.id == id }) else { return }
        theirs.lines[i].copies = max(1, copies)
        reprice()
    }

    /// Re-read the catalog for the union of both columns. Called on every composition change;
    /// the read is indexed and the two columns are a handful of cards, not a tin.
    func reprice() {
        let ids = (yours.lines + theirs.lines).map(\.entry.cardId)
        pricing = TradePrices.load(cardIds: ids, from: store)
    }

    // MARK: Balance

    var yourValue: (total: Double, pricedCards: Int, totalCards: Int) { pricing.value(yours) }
    var theirValue: (total: Double, pricedCards: Int, totalCards: Int) { pricing.value(theirs) }

    var balance: TradeBalance {
        TradeBalance(yourGive: yourValue.total + yours.cashUsd,
                     theirGive: theirValue.total + theirs.cashUsd)
    }

    /// Cards on the table with no price of their own, across both columns. A trade balance that
    /// silently treats unpriced as $0 is worse than one that admits ignorance.
    var unpriced: (unpriced: Int, total: Double) {
        let y = yourValue, t = theirValue
        return ((y.totalCards - y.pricedCards) + (t.totalCards - t.pricedCards),
                Double(y.totalCards + t.totalCards))
    }

    var isExecutable: Bool { !yours.lines.isEmpty || !theirs.lines.isEmpty }

    // MARK: Execute

    /// What executing would write — pure, so the destructive step is testable without a repository.
    ///
    /// Outgoing copies become sold with no proceeds, which is what a trade is: the copy is gone
    /// and there is no cash figure to record. `forTrade` is cleared with it — a card that has left
    /// must not still appear on a list you bring to the next meetup.
    func plan(now: Date = Date()) -> TradePlan {
        var plan = TradePlan()
        for line in yours.lines {
            let row = line.entry
            let copies = min(max(line.copies, 1), row.qty)
            // Money on a row is a total ("Price paid — total"), so it divides across the copies
            // and the cost basis survives the split.
            let share = { (total: Double?) in total.map { $0 / Double(row.qty) } }
            if copies == row.qty {
                var gone = row
                gone.soldAt = now
                gone.soldFor = nil
                gone.forTrade = nil
                plan.updatedEntries.append(gone)
            } else {
                // The REMAINDER keeps the original id: it is the row that continues to exist, so
                // an undo or a backup referencing that id still resolves to a card you own rather
                // than to a closed record.
                var kept = row
                kept.qty = row.qty - copies
                kept.pricePaid = share(row.pricePaid).map { $0 * Double(kept.qty) }
                kept.gradingFeeUsd = share(row.gradingFeeUsd).map { $0 * Double(kept.qty) }

                var gone = row
                gone.id = UUID().uuidString
                gone.qty = copies
                gone.pricePaid = share(row.pricePaid).map { $0 * Double(copies) }
                gone.gradingFeeUsd = share(row.gradingFeeUsd).map { $0 * Double(copies) }
                gone.soldAt = now
                gone.soldFor = nil
                gone.forTrade = nil
                plan.updatedEntries.append(contentsOf: [kept, gone])
            }
        }
        for line in theirs.lines {
            let e = line.entry
            plan.incomingDrafts.append(
                ScanDraft(id: UUID().uuidString, cardId: e.cardId,
                          variant: e.variantValue ?? .regular,
                          condition: e.conditionValue ?? .nm,
                          qty: line.copies, addedAt: now,
                          priceUsdSnapshot: pricing.lineValue(TradeLine(entry: e, copies: 1)),
                          acquiredVia: .traded))
        }
        return plan
    }
}
