import XCTest
@testable import TheTin

final class BinderFillTests: XCTestCase {
    private func entry(_ cardId: String, group: String, qty: Int = 1, variant: String? = nil) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: cardId, groupId: group, qty: qty,
                        condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                        acquiredFrom: nil, addedAt: Date(), variant: variant)
    }

    private func layout(_ slots: [PlannedCard?]) -> BinderLayout {
        BinderLayout(groupId: "binder", shape: PageShape(rows: 1, cols: slots.count),
                     pages: [BinderPage(slots: slots)])
    }

    /// Three slots of the same card against two copies owned: two full, one still needed. Order
    /// decides which, so the answer is stable between renders.
    func testOwnedCopiesAreConsumedInSlotOrder() {
        let l = layout([PlannedCard(cardId: "a"), PlannedCard(cardId: "a"), PlannedCard(cardId: "a")])
        let states = BinderFill.states(layout: l, entries: [entry("a", group: "binder", qty: 2)])
        XCTAssertEqual(states[0], [.filled, .filled, .needed(elsewhere: nil)])
    }

    /// The pull-it-from-the-tin case: you own it, it is just filed somewhere else.
    func testACopyInAnotherDividerReportsThatDivider() {
        let l = layout([PlannedCard(cardId: "a")])
        let states = BinderFill.states(layout: l, entries: [entry("a", group: "vintage")])
        XCTAssertEqual(states[0], [.needed(elsewhere: "vintage")])
    }

    func testAnEmptyPocketIsNeitherFilledNorNeeded() {
        XCTAssertEqual(BinderFill.states(layout: layout([nil]), entries: [])[0], [.empty])
    }

    /// A slot with no variant takes any printing; a slot that names one does not.
    func testVariantMatching() {
        let anyPrinting = layout([PlannedCard(cardId: "a", variant: nil)])
        XCTAssertEqual(
            BinderFill.states(layout: anyPrinting,
                              entries: [entry("a", group: "binder", variant: "reverseHolo")])[0],
            [.filled])

        let reverseOnly = layout([PlannedCard(cardId: "a", variant: "reverseHolo")])
        XCTAssertEqual(
            BinderFill.states(layout: reverseOnly,
                              entries: [entry("a", group: "binder", variant: "holo")])[0],
            [.needed(elsewhere: nil)])
    }

    /// One physical copy cannot fill two pockets, even when one slot is a wildcard.
    func testACopyIsSpentOnce() {
        let l = layout([PlannedCard(cardId: "a", variant: "holo"), PlannedCard(cardId: "a", variant: nil)])
        let states = BinderFill.states(layout: l, entries: [entry("a", group: "binder", variant: "holo")])
        XCTAssertEqual(states[0], [.filled, .needed(elsewhere: nil)])
    }

    /// The generator's OWN ordering: base slot first, reverse-holo slot second. Walking in slot
    /// order let the wildcard base slot eat the reverse copy, so a reverse-only pack pull — the
    /// normal case for a common — read "base: filled, reverse: needed" and sent you shopping for a
    /// card already in the pocket next door.
    private var generatorPair: BinderLayout {
        layout([PlannedCard(cardId: "a", variant: nil),
                PlannedCard(cardId: "a", variant: CardVariant.reverseHolo.rawValue)])
    }

    func testAReverseOnlyCopyFillsTheReversePocketNotTheBaseOne() {
        let states = BinderFill.states(
            layout: generatorPair,
            entries: [entry("a", group: "binder", variant: "reverseHolo")])
        XCTAssertEqual(states[0], [.needed(elsewhere: nil), .filled])
    }

    /// Owning both printings fills both pockets whichever order the repository emits them in —
    /// otherwise two devices with the same cards disagree.
    func testOwningBothPrintingsFillsBothPocketsWhateverTheEntryOrder() {
        let base = entry("a", group: "binder", variant: "regular")
        let reverse = entry("a", group: "binder", variant: "reverseHolo")
        for entries in [[base, reverse], [reverse, base]] {
            XCTAssertEqual(BinderFill.states(layout: generatorPair, entries: entries)[0],
                           [.filled, .filled])
        }
    }

    /// `binders.json` is a trust boundary: a legal PPT printing name has to canonicalise onto the
    /// rawValue the entry side stores, or the pocket never fills.
    func testASlotVariantWrittenAsAPPTPrintingNameStillMatches() {
        let l = layout([PlannedCard(cardId: "a", variant: "Reverse Holofoil")])
        XCTAssertEqual(
            BinderFill.states(layout: l, entries: [entry("a", group: "binder", variant: "reverseHolo")])[0],
            [.filled])
    }
}
