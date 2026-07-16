import XCTest
@testable import TheTin

/// TDD for E2's `CandidateIndex.pool(fields:)` — the soft-narrow ranked candidate pool that
/// feeds the visual matcher.
final class CandidateIndexPoolTests: XCTestCase {
    private func makeIndex() throws -> CandidateIndex {
        try CandidateIndex(store: try FixtureCatalog.make())
    }

    // (a) number+name: text pass (name) AND number pass AND hp all agree — full agreement, ranked first.
    func testNumberAndNameAgreementRanksFirst() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "Rayquaza VMAX", numerators: ["215"], denominator: "203", hp: 320)
        let pool = index.pool(fields: fields)
        XCTAssertEqual(pool.first, "swsh7-215")
        XCTAssertTrue(pool.contains("swsh7-215"))
    }

    // (b) number-only: no text signal, number pass alone still surfaces the card.
    func testNumberOnlyStillSurfacesCard() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: ["215"], denominator: nil, hp: nil)
        let pool = index.pool(fields: fields)
        XCTAssertTrue(pool.contains("swsh7-215"))
    }

    // (c) promo regression: proves the CandidateIndex.swift:13 `-1` collapse is fixed — an
    // alphanumeric promo number must survive the raw-number index, not collide with other promos.
    func testPromoNumberSurvivesRawIndex() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: [FixtureCatalog.promoNumber], denominator: nil, hp: nil)
        let pool = index.pool(fields: fields)
        XCTAssertTrue(pool.contains(FixtureCatalog.promoCardId))
    }

    // (d) attack-name only: name/number absent from the OCR text, attack-name FTS (card_text.body)
    // rescues the card — the holo "biggest win" this task adds.
    func testAttackNameOnlyRescuesCard() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: FixtureCatalog.attackNamePhrase, numerators: [], denominator: nil, hp: nil)
        let pool = index.pool(fields: fields)
        XCTAssertTrue(pool.contains(FixtureCatalog.attackNameCardId))
    }

    // Soft-narrow: a text-only match with no number/hp agreement is still IN the pool (never
    // hard-excluded), just ranked with lower agreement than a full-agreement candidate.
    func testTextOnlyMatchIsIncludedNotExcluded() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "Umbreon V", numerators: [], denominator: nil, hp: nil)
        let pool = index.pool(fields: fields)
        XCTAssertTrue(pool.contains("swsh7-94"))
    }

    // Empty fields (no text, no number) produce an empty pool rather than matching everything.
    func testEmptyFieldsProduceEmptyPool() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: [], denominator: nil, hp: nil)
        XCTAssertTrue(index.pool(fields: fields).isEmpty)
    }

    // Cap: the pool never exceeds 160 ids (fixture is far smaller, so this just checks the
    // contract shape rather than exercising the cap directly).
    func testPoolNeverExceeds160() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "a", numerators: [], denominator: nil, hp: nil)
        XCTAssertLessThanOrEqual(index.pool(fields: fields).count, 160)
    }
}
