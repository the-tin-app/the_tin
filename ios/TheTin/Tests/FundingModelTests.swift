import XCTest
@testable import TheTin

final class FundingModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func snapshot(
        state: String,
        updatedAt: String,
        fundedPct: Double = 0.5,
        monthlyGoalCents: Int = 100_000,
        raisedCents: Int = 50_000
    ) -> Data {
        let json = """
        {
            "state": "\(state)",
            "fundedPct": \(fundedPct),
            "monthlyGoalCents": \(monthlyGoalCents),
            "raisedCents": \(raisedCents),
            "updatedAt": "\(updatedAt)"
        }
        """
        return Data(json.utf8)
    }

    private func decode(_ data: Data) throws -> FundingSnapshot {
        try JSONDecoder().decode(FundingSnapshot.self, from: data)
    }

    // MARK: - FundingSnapshot decoding (wire model — unchanged by the no-gate model)

    func test_decodesRealJSONObject_withGreenState() throws {
        let decoded = try decode(snapshot(
            state: "GREEN", updatedAt: isoString(now),
            fundedPct: 0.75, monthlyGoalCents: 200_000, raisedCents: 150_000))
        XCTAssertEqual(decoded.state, .green)
        XCTAssertEqual(decoded.fundedPct, 0.75)
        XCTAssertEqual(decoded.monthlyGoalCents, 200_000)
        XCTAssertEqual(decoded.raisedCents, 150_000)
    }

    func test_unknownStateString_decodesToUnknown_doesNotThrow() throws {
        XCTAssertEqual(try decode(snapshot(state: "PURPLE", updatedAt: isoString(now))).state, .unknown)
    }

    func test_missingStateKey_decodesToUnknown_doesNotThrow() throws {
        let json = """
        { "fundedPct": 0.75, "monthlyGoalCents": 200000, "raisedCents": 150000, "updatedAt": "\(isoString(now))" }
        """
        let decoded = try decode(Data(json.utf8))
        XCTAssertEqual(decoded.state, .unknown)
        XCTAssertEqual(decoded.fundedPct, 0.75)
    }

    func test_emptyObject_decodesToUnknownWithZeroDefaults_doesNotThrow() throws {
        let decoded = try decode(Data("{}".utf8))
        XCTAssertEqual(decoded.state, .unknown)
        XCTAssertEqual(decoded.fundedPct, 0)
        XCTAssertEqual(decoded.monthlyGoalCents, 0)
        XCTAssertEqual(decoded.raisedCents, 0)
    }

    // MARK: - FundingModel.display (display-only; no gating, no punishing copy)

    func test_display_nilSnapshot_zeroPct_defaultGoal() {
        let d = FundingModel.display(from: nil)
        XCTAssertEqual(d.fundedPct, 0)
        XCTAssertEqual(d.monthlyGoalCents, FundingModel.defaultGoalCents)
        XCTAssertEqual(d.raisedCents, 0)
    }

    func test_display_usesSnapshotValues_andClampsPct() throws {
        let snap = try decode(snapshot(state: "RED", updatedAt: isoString(now),
                                       fundedPct: 1.5, monthlyGoalCents: 15_000, raisedCents: 9_300))
        let d = FundingModel.display(from: snap)
        XCTAssertEqual(d.fundedPct, 1.0)          // clamped — no punishment for any state
        XCTAssertEqual(d.monthlyGoalCents, 15_000)
        XCTAssertEqual(d.raisedCents, 9_300)
    }

    func test_display_negativePct_clampsToZero() throws {
        let snap = try decode(snapshot(state: "GREEN", updatedAt: isoString(now), fundedPct: -0.2))
        XCTAssertEqual(FundingModel.display(from: snap).fundedPct, 0)
    }

    func test_display_zeroGoal_fallsBackToDefault() throws {
        let snap = try decode(snapshot(state: "GREEN", updatedAt: isoString(now), monthlyGoalCents: 0))
        XCTAssertEqual(FundingModel.display(from: snap).monthlyGoalCents, FundingModel.defaultGoalCents)
    }

    func test_dollars_formatsWholeDollars() {
        XCTAssertEqual(FundingModel.dollars(15_000), "$150")
        XCTAssertEqual(FundingModel.dollars(9_312), "$93")
        XCTAssertEqual(FundingModel.dollars(0), "$0")
    }
}
