import XCTest
@testable import TheTin

/// The whole feature is one percentage shown to two people across a table, plus one destructive
/// button. So the tests concentrate on exactly those: who is favored, what the denominator is,
/// and precisely what `execute` would write.
final class TradeBalanceTests: XCTestCase {

    /// The trap this feature could most easily ship: favored is the side that RECEIVES more,
    /// which is the OPPOSITE of the side whose pile is bigger. You hand over your column.
    func testFavoredIsTheSideReceivingMoreNotTheBiggerPile() {
        XCTAssertEqual(TradeBalance(yourGive: 100, theirGive: 120).favored, .you)
        XCTAssertEqual(TradeBalance(yourGive: 120, theirGive: 100).favored, .them)
        XCTAssertEqual(TradeBalance(yourGive: 100, theirGive: 100).favored, .even)
    }

    /// "Favored by 12%" means the gap is 12% of the LARGER pile — not of the smaller one, and not
    /// of the total. The UI states the denominator for this reason.
    func testPercentIsTheGapOverTheLargerPile() {
        XCTAssertEqual(TradeBalance(yourGive: 100, theirGive: 88).percent, 0.12, accuracy: 0.0001)
        XCTAssertEqual(TradeBalance(yourGive: 88, theirGive: 100).percent, 0.12, accuracy: 0.0001)
        // 50 against 100 is 50% of the larger pile, not 100% of the smaller.
        XCTAssertEqual(TradeBalance(yourGive: 50, theirGive: 100).percent, 0.5, accuracy: 0.0001)
    }

    /// The screen opens empty, so this branch runs before any other — it must not divide by zero.
    func testAnEmptyTradeIsEvenAtZeroPercent() {
        let b = TradeBalance(yourGive: 0, theirGive: 0)
        XCTAssertEqual(b.favored, .even)
        XCTAssertEqual(b.percent, 0)
    }

    func testOneEmptySideIsFullyFavoured() {
        let b = TradeBalance(yourGive: 0, theirGive: 40)
        XCTAssertEqual(b.favored, .you)
        XCTAssertEqual(b.percent, 1.0, accuracy: 0.0001)
    }
}

@MainActor
final class TradeSessionTests: XCTestCase {
    /// Rayquaza VMAX — $92.50 raw in the fixture, no variant or condition rows.
    private let ray = "swsh7-215"
    /// Metapod — in the fixture's card table with no price row at all.
    private let unpricedCard = "swsh7-12"

    private var store: CatalogStore!

    override func setUpWithError() throws { store = try FixtureCatalog.make() }
    override func tearDownWithError() throws { try store?.close() }

    private func owned(_ id: String, card: String? = nil, qty: Int = 1,
                       pricePaid: Double? = nil) -> CollectionEntry {
        CollectionEntry(id: id, cardId: card ?? ray, groupId: "g1", qty: qty, condition: "NM",
                        grade: nil, pricePaid: pricePaid, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date(timeIntervalSince1970: 0), variant: nil, forTrade: true)
    }

    // MARK: Composition

    func testOfferingTheSameRowTwiceBumpsCopiesRatherThanDuplicatingTheLine() {
        let s = TradeSession(store: store)
        let row = owned("e1", qty: 3)
        s.offer(row); s.offer(row)
        XCTAssertEqual(s.yours.lines.count, 1)
        XCTAssertEqual(s.yours.lines[0].copies, 2)
    }

    /// You cannot put four copies on the table when you own three — the split at execute divides
    /// a real stack, so an over-count would invent cards.
    func testCopiesNeverExceedWhatYouOwn() {
        let s = TradeSession(store: store)
        let row = owned("e1", qty: 2)
        s.offer(row); s.offer(row); s.offer(row)
        XCTAssertEqual(s.yours.lines[0].copies, 2)

        s.setCopies(99, forYourLine: "e1")
        XCTAssertEqual(s.yours.lines[0].copies, 2)
        s.setCopies(0, forYourLine: "e1")
        XCTAssertEqual(s.yours.lines[0].copies, 1)
    }

    /// A second copy of their card in a DIFFERENT condition is a different line, because it is
    /// worth a different amount. Folding them together would misprice the column.
    func testTheirSideSeparatesLinesByCondition() {
        let s = TradeSession(store: store)
        s.request(cardId: ray, rarity: nil, condition: .nm)
        s.request(cardId: ray, rarity: nil, condition: .nm)
        XCTAssertEqual(s.theirs.lines.count, 1)
        XCTAssertEqual(s.theirs.lines[0].copies, 2)

        s.request(cardId: ray, rarity: nil, condition: .lp)
        XCTAssertEqual(s.theirs.lines.count, 2)
    }

    // MARK: Balance

    func testBothColumnsArePricedByTheSameLadder() {
        let s = TradeSession(store: store)
        s.offer(owned("e1"))
        s.request(cardId: ray, rarity: nil)
        XCTAssertEqual(s.yourValue.total, 92.5, accuracy: 0.001)
        XCTAssertEqual(s.theirValue.total, 92.5, accuracy: 0.001)
        XCTAssertEqual(s.balance.favored, .even)
    }

    func testCashOnASideShiftsTheFavouredSide() {
        let s = TradeSession(store: store)
        s.offer(owned("e1"))                          // you give $92.50
        s.request(cardId: ray, rarity: nil)           // they give $92.50
        XCTAssertEqual(s.balance.favored, .even)

        s.theirs.cashUsd = 20                         // they sweeten it
        XCTAssertEqual(s.balance.favored, .you)

        s.theirs.cashUsd = 0
        s.yours.cashUsd = 20                          // you sweeten it
        XCTAssertEqual(s.balance.favored, .them)
    }

    /// Cash must not count as a card, or "3 of 14 priced" starts lying the moment anyone adds $5.
    func testCashIsNotCountedAsACard() {
        let s = TradeSession(store: store)
        s.offer(owned("e1"))
        s.yours.cashUsd = 50
        XCTAssertEqual(s.yourValue.totalCards, 1)
        XCTAssertEqual(s.balance.yourGive, 142.5, accuracy: 0.001)
    }

    /// An unpriced card silently treated as $0 is worse than one that admits ignorance — this is
    /// what the "N of M cards priced" line is computed from.
    func testUnpricedCardsAreCountedAcrossBothSides() {
        let s = TradeSession(store: store)
        s.offer(owned("e1", card: unpricedCard))
        s.request(cardId: ray, rarity: nil)
        XCTAssertEqual(s.unpriced.unpriced, 1)
        XCTAssertEqual(s.unpriced.total, 2)
    }

    // MARK: Execute

    func testOutgoingCopiesBecomeSoldWithNoProceeds() throws {
        let s = TradeSession(store: store)
        s.offer(owned("e1"))
        let now = Date(timeIntervalSince1970: 1_000)

        let plan = s.plan(now: now)
        XCTAssertEqual(plan.updatedEntries.count, 1)
        let gone = try XCTUnwrap(plan.updatedEntries.first)
        XCTAssertEqual(gone.id, "e1")           // a whole row keeps its id
        XCTAssertEqual(gone.soldAt, now)
        XCTAssertNil(gone.soldFor)              // a trade has no cash figure — that is the point
        XCTAssertNil(gone.forTrade)             // gone cards must not stay on the trade list
    }

    /// Trading 1 of 3 splits the stack: the remainder keeps the original id (it is the row that
    /// continues to exist, so a backup or undo referencing it still resolves to a card you own),
    /// and the traded copies leave as a new closed record.
    func testTradingPartOfAStackSplitsItAndDividesTheCostBasis() throws {
        let s = TradeSession(store: store)
        s.offer(owned("e1", qty: 3, pricePaid: 30))
        s.setCopies(1, forYourLine: "e1")

        let plan = s.plan(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(plan.updatedEntries.count, 2)
        let kept = try XCTUnwrap(plan.updatedEntries.first { $0.id == "e1" })
        let gone = try XCTUnwrap(plan.updatedEntries.first { $0.id != "e1" })

        XCTAssertEqual(kept.qty, 2)
        XCTAssertNil(kept.soldAt)
        XCTAssertEqual(try XCTUnwrap(kept.pricePaid), 20, accuracy: 0.001)

        XCTAssertEqual(gone.qty, 1)
        XCTAssertNotNil(gone.soldAt)
        XCTAssertEqual(try XCTUnwrap(gone.pricePaid), 10, accuracy: 0.001)

        // No cost basis is invented or destroyed by the split.
        XCTAssertEqual(try XCTUnwrap(kept.pricePaid) + XCTUnwrap(gone.pricePaid), 30, accuracy: 0.001)
    }

    /// Nothing enters the tin unreviewed — incoming cards land in scan staging, pre-tagged so the
    /// review screen already knows how they were acquired.
    func testIncomingCardsLandInStagingMarkedAsTraded() throws {
        let s = TradeSession(store: store)
        s.request(cardId: ray, rarity: nil, condition: .lp)
        s.setCopies(2, forTheirLine: try XCTUnwrap(s.theirs.lines.first).id)

        let plan = s.plan(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(plan.updatedEntries.isEmpty)
        let draft = try XCTUnwrap(plan.incomingDrafts.first)
        XCTAssertEqual(draft.cardId, ray)
        XCTAssertEqual(draft.condition, .lp)
        XCTAssertEqual(draft.qty, 2)
        XCTAssertEqual(draft.acquiredVia, .traded)
    }

    /// Their side is synthetic and must never be mistaken for something you own: a trade with
    /// cards only on their side writes no collection rows at all.
    func testTheirSideNeverWritesCollectionRows() {
        let s = TradeSession(store: store)
        s.request(cardId: ray, rarity: nil)
        XCTAssertTrue(s.plan().updatedEntries.isEmpty)
    }

    // MARK: Printing

    /// The printing is a real rung of the price ladder, and `defaultFor(rarity:)` can only ever
    /// guess `.regular` or `.holo` — so a reverse holo or a 1st Edition on their side is only
    /// reachable if it is settable.
    func testTheirPrintingIsSettableToTheOnesNoGuessCanReach() throws {
        let s = TradeSession(store: store)
        s.request(cardId: ray, rarity: "Secret Rare")
        let id = try XCTUnwrap(s.theirs.lines.first).id
        XCTAssertEqual(s.theirs.lines[0].entry.variantValue, .regular)

        s.setVariant(.reverseHolo, forTheirLine: id)
        XCTAssertEqual(s.theirs.lines[0].entry.variantValue, .reverseHolo)
        s.setVariant(.firstEdition, forTheirLine: id)
        XCTAssertEqual(s.theirs.lines[0].entry.variantValue, .firstEdition)
    }

    /// A card that arrived by shared link and the same card added by search must be the same
    /// card. Seeding used to leave `variant` nil, which skips the per-printing rung entirely —
    /// so the two paths could price one card two ways.
    func testASeededCardCarriesAPrintingJustLikeASearchedOne() throws {
        let rarity = (try? store.card(id: ray))?.rarity

        let seeded = TradeSession(store: store)
        seeded.seedTheirSide(from: ShareList.Payload(k: .trade, i: [ShareList.Item(c: ray)]))

        let searched = TradeSession(store: store)
        searched.request(cardId: ray, rarity: rarity)

        let a = try XCTUnwrap(seeded.theirs.lines.first).entry.variantValue
        XCTAssertNotNil(a)
        XCTAssertEqual(a, try XCTUnwrap(searched.theirs.lines.first).entry.variantValue)
    }

    // MARK: Undo

    /// Undo is a write, not a reconstruction, so the plan has to carry the rows as they were —
    /// verbatim, including the fields a trade never touches.
    func testThePlanCarriesTheRowsAsTheyWereSoUndoIsAWrite() throws {
        let before = owned("e1", qty: 2, pricePaid: 40)
        let s = TradeSession(store: store)
        s.offer(before)

        let plan = s.plan(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(plan.originalEntries, [before])
    }

    /// A stack traded in part mints a second row. Restoring the originals alone would leave that
    /// row behind and the copies would exist twice — so the minted ids travel with the plan.
    func testAPartialSplitRecordsTheIdItMintedSoUndoCanDeleteIt() throws {
        let s = TradeSession(store: store)
        s.offer(owned("e1", qty: 3, pricePaid: 30))
        s.setCopies(1, forYourLine: "e1")

        let plan = s.plan(now: Date(timeIntervalSince1970: 1_000))
        let gone = try XCTUnwrap(plan.updatedEntries.first { $0.id != "e1" })
        XCTAssertEqual(plan.mintedIds, [gone.id])
        // The row that continues to exist keeps its id, so it is restored by overwrite, not by
        // deletion — undo must never delete a card you still own.
        XCTAssertEqual(plan.originalEntries.map(\.id), ["e1"])
        XCTAssertFalse(plan.mintedIds.contains("e1"))
    }

    /// A whole-stack trade mints nothing: the sold row IS the original row, so undo is one
    /// overwrite and deleting anything would be wrong.
    func testTradingAWholeStackMintsNothingToDelete() {
        let s = TradeSession(store: store)
        s.offer(owned("e1", qty: 2))
        // `offer` puts ONE copy on the table, so the whole stack has to be asked for explicitly —
        // otherwise this is the partial-split case wearing a whole-stack name.
        s.setCopies(2, forYourLine: "e1")
        XCTAssertTrue(s.plan().mintedIds.isEmpty)
    }
}
