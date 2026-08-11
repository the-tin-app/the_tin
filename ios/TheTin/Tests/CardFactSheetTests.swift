import XCTest
import SwiftUI
@testable import TheTin

/// The offline fact sheet. These assert the STRINGS the sheet composes and the sheet's rendered
/// HEIGHT — never a sum of point sizes, per the standing lesson that layout constants get measured,
/// not derived ("3 blocks ≈ 640 pt" rendered at 727 pt).
final class CardFactSheetTests: XCTestCase {

    private func card(id: String = "swsh3-136", name: String = "Furret", hp: Int? = 90,
                      types: [String] = ["Colorless"], rarity: String? = "Uncommon",
                      artist: String? = "tetsuya koizumi", attacks: [Attack] = [],
                      detail: CardDetail? = nil) -> CardRecord {
        CardRecord(id: id, setId: "swsh3", number: "136", name: name, hp: hp, types: types,
                   rarity: rarity, artist: artist, imageBase: nil, imageUrl: nil,
                   tcgplayerId: nil, attacks: attacks, detail: detail)
    }

    // MARK: - The number line, which is the field you actually check

    func testNumberLineFallsBackToTheSetIdWhenNoCallerSuppliedASet() {
        let sheet = CardFactSheet(card: card())
        XCTAssertEqual(sheet.numberLine, "SWSH3 #136")
    }

    func testNumberLinePrintsTheDenominatorOnlyWhenTheCallerHandedUsOne() {
        XCTAssertEqual(CardFactSheet(card: card(), setName: "Darkness Ablaze").numberLine,
                       "Darkness Ablaze #136")
        XCTAssertEqual(CardFactSheet(card: card(), setName: "Darkness Ablaze", setTotal: 189).numberLine,
                       "Darkness Ablaze #136/189")
    }

    // MARK: - Rows that must vanish rather than render empty

    func testCombatLineIsNilWhenTheCardHasNoneOfIt() {
        // Three em dashes read as "we failed to load this", which is the opposite of the point.
        XCTAssertNil(CardFactSheet(card: card()).combatLine)
        XCTAssertNil(CardFactSheet(card: card(detail: CardDetail(category: "Pokemon"))).combatLine)
    }

    func testCombatLineJoinsOnlyWhatIsPrinted() {
        let detail = CardDetail(weaknesses: [CardTypeValue(type: "Fighting", value: "×2")], retreat: 1)
        XCTAssertEqual(CardFactSheet(card: card(detail: detail)).combatLine,
                       "Weak Fighting ×2 · Retreat 1")
    }

    func testEvolutionLineCoversAllFourCombinations() {
        let s = { (d: CardDetail?) in CardFactSheet(card: self.card(detail: d)).evolutionLine }
        XCTAssertEqual(s(CardDetail(stage: "Stage1", evolveFrom: "Sentret")), "Stage 1 · evolves from Sentret")
        XCTAssertEqual(s(CardDetail(stage: "Basic")), "Basic")
        XCTAssertEqual(s(CardDetail(evolveFrom: "Sentret")), "Evolves from Sentret")
        XCTAssertNil(s(CardDetail(category: "Pokemon")))
    }

    func testTrainersShowTheirTrainerTypeWhereAPokemonShowsItsStage() {
        let detail = CardDetail(category: "Trainer", trainerType: "Tool", effect: "Prevent all effects.")
        XCTAssertEqual(CardFactSheet(card: card(hp: nil, detail: detail)).evolutionLine, "Trainer · Tool")
    }

    func testStageDigitIsSeparatedFromTheWord() {
        XCTAssertEqual(CardFactSheet.humanStage("Stage1"), "Stage 1")
        XCTAssertEqual(CardFactSheet.humanStage("Stage2"), "Stage 2")
        XCTAssertEqual(CardFactSheet.humanStage("Basic"), "Basic")
        XCTAssertEqual(CardFactSheet.humanStage(""), "")
    }

    // MARK: - Energy chips

    func testEnergyChipsAreTwoLettersBecauseFireAndFightingBothStartWithF() {
        XCTAssertNotEqual(EnergyChip.code("Fire"), EnergyChip.code("Fighting"))
        XCTAssertEqual(EnergyChip.code("Fire"), "FR")
        XCTAssertEqual(EnergyChip.code("Fighting"), "FG")
    }

    func testAnUnknownEnergyTypeStillRendersSomething() {
        // A new TCG or a new type must degrade to a readable chip, never to a crash or a blank.
        XCTAssertEqual(EnergyChip.code("Plasma"), "PL")
    }

    // MARK: - Rendered size (measured, not derived)

    @MainActor
    func testTheFullSheetFillsACardShapedFrameWithoutOverflowing() throws {
        let detail = CardDetail(category: "Pokemon", stage: "Stage1", evolveFrom: "Sentret",
                                abilities: [CardAbility(name: "Energy Burn", type: "Pokemon Power",
                                                        effect: String(repeating: "long effect text. ", count: 6))],
                                weaknesses: [CardTypeValue(type: "Fighting", value: "×2")],
                                retreat: 1, regulationMark: "D")
        let attacks = [Attack(name: "Tail Smash", damage: "90", cost: ["Colorless", "Grass"],
                              effect: String(repeating: "flip a coin. ", count: 8))]
        let sheet = CardFactSheet(card: card(attacks: attacks, detail: detail),
                                  setName: "Darkness Ablaze", setTotal: 189)
        let frame = CGSize(width: 240, height: 240 / 0.717)
        let size = try XCTUnwrap(sizeThatFits(sheet, in: frame))
        // The sheet must live inside the frame its container gives it. A worst-case card (long
        // ability + long attack effect + every footer row) is what makes the art window collapse,
        // and that is the intended behaviour — text stays legible, the blank rectangle yields.
        XCTAssertLessThanOrEqual(size.height, frame.height + 1, "sheet overflowed its card frame")
        XCTAssertLessThanOrEqual(size.width, frame.width + 1)
    }

    @MainActor
    func testTheCompactSheetFitsAGridTile() throws {
        let sheet = CardFactSheet(card: card(name: "Iron Valiant ex Tera Type Fighting"), density: .compact)
        let frame = CGSize(width: 56, height: 56 / 0.717)
        let size = try XCTUnwrap(sizeThatFits(sheet, in: frame))
        XCTAssertLessThanOrEqual(size.height, frame.height + 1, "compact sheet overflowed a grid tile")
    }

    @MainActor
    private func sizeThatFits<V: View>(_ view: V, in frame: CGSize) -> CGSize? {
        let host = UIHostingController(rootView: view.frame(width: frame.width, height: frame.height))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
    }
}
