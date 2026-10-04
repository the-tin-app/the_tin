import XCTest
@testable import TheTin

/// #193: sorting and narrowing a divider by what's printed on the cards.
final class TinListOptionsTests: XCTestCase {
    private func card(_ id: String, _ name: String, set: String = "s1", number: String = "1",
                      hp: Int? = nil, types: [String] = [], rarity: String? = nil,
                      category: String? = "Pokemon", stage: String? = nil,
                      weak: [String] = []) -> CardRecord {
        CardRecord(id: id, setId: set, number: number, name: name, hp: hp, types: types,
                   rarity: rarity, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil,
                   detail: CardDetail(category: category, stage: stage,
                                      weaknesses: weak.map { CardTypeValue(type: $0, value: "×2") }))
    }

    private func entry(_ id: String, _ cardId: String, added: TimeInterval = 0) -> CollectionEntry {
        CollectionEntry(id: id, cardId: cardId, groupId: "", qty: 1, condition: "NM", grade: nil,
                        pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date(timeIntervalSince1970: added))
    }

    private lazy var cards: [String: CardRecord] = Dictionary(uniqueKeysWithValues: [
        card("abra", "Abra", set: "base1", number: "43", hp: 30, types: ["Psychic"], rarity: "Common",
             stage: "Basic", weak: ["Psychic"]),
        card("kadabra", "Kadabra", set: "base1", number: "32", hp: 60, types: ["Psychic"], rarity: "Uncommon",
             stage: "Stage 1", weak: ["Psychic"]),
        card("charizard", "Charizard", set: "base1", number: "4", hp: 120, types: ["Fire"], rarity: "Rare Holo",
             stage: "Stage 2", weak: ["Water"]),
        card("mew", "Mew ex", set: "sv3pt5", number: "151", hp: 180, types: ["Psychic"],
             rarity: "Double rare", stage: "Basic", weak: ["Darkness"]),
        card("potion", "Potion", set: "sv1", number: "188", rarity: "Uncommon", category: "Trainer"),
        card("pika-sir", "Pikachu", set: "sv3pt5", number: "173", hp: 60, types: ["Lightning"],
             rarity: "Special illustration rare", stage: "Basic", weak: ["Fighting"]),
    ].map { ($0.id, $0) })
    private let releases = ["base1": "1999-01-09", "sv1": "2023-03-31", "sv3pt5": "2023-09-22"]

    private func sorted(_ by: TinSort, _ entries: [CollectionEntry]? = nil) -> [String] {
        let cards = self.cards, releases = self.releases
        let list = entries ?? cards.keys.sorted().map { entry("e-\($0)", $0) }
        return TinSorting.sorted(list, by: by, card: { cards[$0] }, setDate: { releases[$0] },
                                 value: { _ in nil }).map(\.cardId)
    }

    func testSetOrderIsReleaseDateThenPrintedNumber() {
        XCTAssertEqual(sorted(.setOldest), ["charizard", "kadabra", "abra", "potion", "mew", "pika-sir"])
        XCTAssertEqual(sorted(.setNewest).prefix(2), ["mew", "pika-sir"])
    }

    func testRarestFirst() {
        XCTAssertEqual(sorted(.rarity).first, "pika-sir")
        XCTAssertEqual(sorted(.rarity).last, "abra")
    }

    /// No HP is not 0 HP — a Trainer sinks below every Pokémon.
    func testHighestHPWithTrainersLast() {
        XCTAssertEqual(sorted(.hp), ["mew", "charizard", "kadabra", "pika-sir", "abra", "potion"])
    }

    func testNewestFirstIsRecentlyAdded() {
        let list = [entry("1", "abra", added: 10), entry("2", "mew", added: 30), entry("3", "potion", added: 20)]
        XCTAssertEqual(sorted(.newest, list), ["mew", "potion", "abra"])
    }

    func testHighestValueSinksUnpricedRows() {
        let list = [entry("1", "abra"), entry("2", "mew"), entry("3", "potion")]
        let values: [String: Double] = ["1": 2, "2": 40]
        let out = TinSorting.sorted(list, by: .value, card: { _ in nil }, setDate: { _ in nil },
                                    value: { values[$0.id] })
        XCTAssertEqual(out.map(\.id), ["2", "1", "3"])
    }

    func testRarityRankLadder() {
        let ranked = ["Common", "Uncommon", "Promo", "Rare", "Rare Holo", "Double rare",
                      "Illustration rare", "Ultra Rare", "Special illustration rare", "Hyper rare"]
            .map(TinSorting.rarityRank)
        XCTAssertEqual(ranked, ranked.sorted(), "each rung outranks the one before it")
        XCTAssertEqual(TinSorting.rarityRank("Rare Holo VMAX"), TinSorting.rarityRank("Double rare"))
        XCTAssertEqual(TinSorting.rarityRank(nil), 0)
    }

    // MARK: filter

    func testFilterByTypeAndStage() {
        var f = TinFilter()
        f.type = "Psychic"
        XCTAssertEqual(cards.values.filter(f.matches).map(\.id).sorted(), ["abra", "kadabra", "mew"])
        f.stage = "Basic"
        XCTAssertEqual(cards.values.filter(f.matches).map(\.id).sorted(), ["abra", "mew"])
        XCTAssertEqual(f.summary, "Psychic · Basic")
    }

    func testTrainersAreAStage() {
        var f = TinFilter()
        f.stage = "Trainer"
        XCTAssertEqual(cards.values.filter(f.matches).map(\.id), ["potion"])
    }

    func testFilterByWeakness() {
        var f = TinFilter()
        f.weakness = "Psychic"
        XCTAssertEqual(cards.values.filter(f.matches).map(\.id).sorted(), ["abra", "kadabra"])
        XCTAssertEqual(f.summary, "Weak to Psychic")
    }

    /// A card the catalog doesn't know can't satisfy a filter, but passes when none is on.
    func testUnknownCardOnlyPassesAnInactiveFilter() {
        XCTAssertTrue(TinFilter().matches(nil))
        var f = TinFilter()
        f.rarity = "Common"
        XCTAssertFalse(f.matches(nil))
    }

    /// Menus offer only what's in the list, stages in evolution order rather than A–Z.
    func testOptionsComeFromTheListInAUsefulOrder() {
        let o = TinFilter.options(for: Array(cards.values))
        XCTAssertEqual(o.types, ["Fire", "Lightning", "Psychic"])
        XCTAssertEqual(o.stages, ["Basic", "Stage 1", "Stage 2", "Trainer"])
        XCTAssertEqual(o.weaknesses, ["Darkness", "Fighting", "Psychic", "Water"])
        XCTAssertEqual(o.rarities.first, "Common")
        XCTAssertEqual(o.rarities.last, "Special illustration rare")
    }
}
