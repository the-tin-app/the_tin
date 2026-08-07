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

    // The printed denominator ranks, and must be able to OVERTURN the id-ascending tiebreak.
    //
    // Without it every text-or-number hit ties on agreement and the order is alphabetical luck —
    // which is what made an iPad ORB-match dozens of wrong cards before reaching the right one at
    // 5.0s per heavy frame (2026-07-27). `matchRanked` early-exits per batch of 16, so rank IS
    // cost. swsh7 is the honest case: its printed_total (203) differs from its catalog total (237),
    // and "swsh7-215" sorts AFTER both Pikachus, so alphabetical order alone puts it last.
    func testDenominatorOutranksAlphabeticalTie() throws {
        let index = try makeIndex()
        // Text hits both Pikachus; the number hits swsh7-215 only. All three tie at agreement 1…
        let tied = OcrFields(rawText: "Pikachu", numerators: ["215"], denominator: nil, hp: nil)
        XCTAssertEqual(index.pool(fields: tied).first, "sv1-25", "alphabetical order without a denominator")

        // …until the denominator matches swsh7's printed_total, which lifts it a tier.
        let withDenom = OcrFields(rawText: "Pikachu", numerators: ["215"],
                                  denominator: String(FixtureCatalog.printedTotalValue), hp: nil)
        XCTAssertEqual(index.pool(fields: withDenom).first, "swsh7-215")
    }

    // Soft-narrow holds for the denominator too: it is a RANKING signal, never a filter. A printed
    // total that matches no set in the pool must reorder nothing and exclude nobody — the EX-era
    // secret-rare case where the printed denominator legitimately differs from the catalog total.
    func testDenominatorNeverExcludes() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "Pikachu", numerators: ["215"], denominator: "9999", hp: nil)
        let pool = index.pool(fields: fields)
        for id in ["sv1-25", "svp-025", "swsh7-215"] {
            XCTAssertTrue(pool.contains(id), "\(id) must survive a non-matching denominator")
        }
    }

    // MARK: - consistency(): the twin guard, read from `card_twin`

    /// ⚠️ **The one link in the chain that was dead in production, and the only one nothing tested.**
    /// Every consumer of `hasTwinInPool` — `ScanSession`'s F1 gate, `LensMatcher.verdict` — is tested
    /// with a stub that simply asserts the flag. Nothing asserted that `CandidateIndex.consistency`
    /// actually reads `card_twin` and sets it, and `card_twin` was 0 rows in every published catalog
    /// for months (the pairs file was gitignored and outside the pipeline's Docker build context), so
    /// the guard was inert the whole time and the tests were all green.
    ///
    /// The cost was a confident wrong answer in the measured fixture set: a Blastoise photographed off
    /// a binder page came back as `cel25cc-CC001`, a third identical-art reprint, with nothing to
    /// withhold the lock. ⚠️ That is the ONLY failure mode this guard addresses — wrong locks seen on a
    /// real device were plainly wrong cards rather than paired art (Tomas, 2026-08-07), so do not read
    /// a populated `card_twin` as a fix for those.
    func testAWinnerWithATwinInThePoolIsReportedAsSuch() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: [], denominator: nil, hp: nil)
        let both = index.consistency(cardId: FixtureCatalog.twinA, fields: fields,
                                     pool: [FixtureCatalog.twinA, FixtureCatalog.twinB])
        XCTAssertTrue(both.hasTwinInPool, "card_twin is not being read")

        // Symmetric: the table holds both directions, so it does not matter which one the matcher won.
        XCTAssertTrue(index.consistency(cardId: FixtureCatalog.twinB, fields: fields,
                                        pool: [FixtureCatalog.twinA, FixtureCatalog.twinB])
                        .hasTwinInPool)
    }

    /// The guard is about the POOL, not about existing. A card with a twin the matcher never had to
    /// choose between is not ambiguous, and flagging it would withhold locks for no reason.
    func testATwinOutsideThePoolDoesNotWithholdAnything() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: [], denominator: nil, hp: nil)
        XCTAssertFalse(index.consistency(cardId: FixtureCatalog.twinA, fields: fields,
                                          pool: [FixtureCatalog.twinA]).hasTwinInPool)
    }

    func testACardWithNoTwinsIsNeverFlagged() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "", numerators: [], denominator: nil, hp: nil)
        XCTAssertFalse(index.consistency(cardId: "swsh7-215", fields: fields,
                                          pool: ["swsh7-215", FixtureCatalog.twinA]).hasTwinInPool)
    }

    // Cap: the pool never exceeds 160 ids (fixture is far smaller, so this just checks the
    // contract shape rather than exercising the cap directly).
    func testPoolNeverExceeds160() throws {
        let index = try makeIndex()
        let fields = OcrFields(rawText: "a", numerators: [], denominator: nil, hp: nil)
        XCTAssertLessThanOrEqual(index.pool(fields: fields).count, 160)
    }
}
