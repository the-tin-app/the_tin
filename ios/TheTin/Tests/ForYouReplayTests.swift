import XCTest
@testable import TheTin

/// Replays `ShelfBuilder` against REAL device data when a fixture directory is present, and skips
/// otherwise.
///
/// ⚠️ **This exists because unit tests prove the logic and say nothing about whether it BITES.**
/// Against a 3-card simulator tin every mechanism in the previous branch fired; against the real
/// 60-card collection all three measured as no-ops, with the suite green throughout. The same thing
/// happened again in this branch: `cardsInPriceBand` shipped with `ORDER BY c.id LIMIT 600`, which
/// truncated the candidate window *alphabetically* and excluded every `sv*`/`swsh*`/`me*` card —
/// 10 unit tests passed, because the fixture had two in-band cards.
///
/// Populate the fixture directory with:
/// ```
/// D=443B6860-F647-5A47-811D-ABFA76C38A9B
/// for f in collection.json wants.json set-goals.json discover-signals.json; do
///   xcrun devicectl device copy from --device $D --domain-type appDataContainer \
///     --domain-identifier ai.reyes.thetin --source "Library/Application Support/$f" \
///     --destination "$TIN_REPLAY_DIR/$f"
/// done
/// xcrun devicectl device copy from --device $D --domain-type appDataContainer \
///   --domain-identifier ai.reyes.thetin \
///   --source "Library/Application Support/Catalog/catalog.sqlite" \
///   --destination "$TIN_REPLAY_DIR/catalog.sqlite"
/// ```
/// Then run with `TIN_REPLAY_DIR=<dir>` in the environment.
final class ForYouReplayTests: XCTestCase {
    /// `LocalCollectionRepository.Snapshot` is private; only the entries are needed here.
    private struct CollectionFixture: Codable { var entries: [CollectionEntry] }

    private var dir: URL? {
        ProcessInfo.processInfo.environment["TIN_REPLAY_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// `@MainActor` because `SetGoalsModel.load` is isolated to it — using the real loader beats
    /// duplicating the decode and letting the two drift.
    @MainActor
    func testShelvesAgainstRealDeviceData() throws {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("catalog.sqlite").path)
        else { throw XCTSkip("Set TIN_REPLAY_DIR to a directory of real device data — see the header.") }

        let store = try CatalogStore(path: dir.appendingPathComponent("catalog.sqlite").path)
        let entries = try JSONDecoder().decode(
            CollectionFixture.self,
            from: Data(contentsOf: dir.appendingPathComponent("collection.json"))).entries
        let wants = try JSONDecoder().decode(
            [String: WantEntry].self, from: Data(contentsOf: dir.appendingPathComponent("wants.json")))
        let goals = SetGoalsModel.load(from: dir.appendingPathComponent("set-goals.json"))
        let signals = DiscoverSignalsModel.load(from: dir.appendingPathComponent("discover-signals.json"))

        let ownedIds = entries.map(\.cardId)
        let tasteIds = Set(ownedIds).union(wants.keys)
        let owned = try store.cards(ids: ownedIds)
        let wanted = try store.cards(ids: Array(wants.keys))
        let tasteDex = try store.dexIds(forCards: Array(tasteIds))
        var profile = DiscoverAffinity.profile(owned: owned, wanted: wanted, dexIds: tasteDex,
                                               priorities: wants.mapValues(\.priority))

        let reasons = (signals.reasons ?? [:]).compactMapValues(DismissReason.init(rawValue:))
        let dismissed = signals.dismissed ?? []
        var band = PriceBand.make(entries: entries, wants: wants, now: Date())
        var ceiling: Double?
        if !reasons.isEmpty {
            let ids = Array(reasons.keys)
            let cards = Dictionary(uniqueKeysWithValues: (try store.cards(ids: ids)).map { ($0.id, $0) })
            let feedback = DiscoverFeedback.derive(
                reasons: reasons, cards: cards,
                dexIds: try store.dexIds(forCards: ids),
                prices: (try store.prices(cardIds: ids)).compactMapValues(\.rawUsd))
            profile = feedback.apply(to: profile)
            band = feedback.apply(to: band)
            ceiling = feedback.priceCeiling
        }
        let related = DiscoverAffinity.relatedSpecies(
            seed: profile.species,
            coOccurring: try store.coOccurringDexIds(with: Array(profile.species.keys)))

        let shelves = ShelfBuilder.build(store: store, profile: profile, band: band, setGoals: goals,
                                         owned: Set(ownedIds), tasteIds: tasteIds,
                                         dismissed: dismissed, priceCeiling: ceiling,
                                         relatedSpecies: related)

        let prices = try store.previewPrices(cardIds: shelves.flatMap(\.cardIds))
        print("""

        ── REPLAY ────────────────────────────────────────────────────────────
        entries=\(entries.count) wants=\(wants.count) goals=\(goals.sorted()) \
        dismissed=\(dismissed.count) species=\(profile.species.count)→\(related.count)
        band=\(band.map { "$\($0.p25)–$\($0.p75)" } ?? "nil") ceiling=\(ceiling.map { "$\($0)" } ?? "nil")
        """)
        for shelf in shelves {
            let head = shelf.cardIds.prefix(3)
                .map { "\($0) $\(Int(prices[$0] ?? 0))" }.joined(separator: ", ")
            print("  [\(shelf.kind.rawValue)] \(shelf.title) — \(shelf.cardIds.count): \(head)")
        }
        let distinctSets = Set(shelves.flatMap(\.cardIds).map { $0.split(separator: "-").dropLast().joined(separator: "-") })
        print("  distinct sets across all shelves: \(distinctSets.count)")

        // ⚠️ Cross-shelf overlap is its own failure mode, and it is invisible to the round-robin:
        // `ForYouStream` dedupes, but `ForYouShelvesView` renders these rows SIMULTANEOUSLY, so two
        // rows leading with the same three cards is what the user actually sees. Every shelf ranks
        // by the same global affinity score, so shelves with overlapping candidates converge.
        print("  cross-shelf overlap:")
        var worstOverlap = 0
        for i in shelves.indices {
            for j in shelves.indices where j > i {
                let shared = Set(shelves[i].cardIds).intersection(shelves[j].cardIds)
                guard !shared.isEmpty else { continue }
                let headShared = Array(shelves[i].cardIds.prefix(3)) == Array(shelves[j].cardIds.prefix(3))
                worstOverlap = max(worstOverlap, shared.count)
                print("    \(shelves[i].id) / \(shelves[j].id): \(shared.count) shared\(headShared ? "  ⚠️ IDENTICAL first 3" : "")")
            }
        }
        print("  worst pairwise overlap: \(worstOverlap)")
        print("──────────────────────────────────────────────────────────────────────\n")

        // --- assertions that would have caught this session's bugs ---
        XCTAssertFalse(shelves.isEmpty, "a real 60-card collection must produce shelves")
        XCTAssertNotNil(shelves.first { $0.kind == .setGoal },
                        "two set goals exist on this device; the shelf must render")

        for shelf in shelves {
            XCTAssertLessThanOrEqual(shelf.cardIds.count, ShelfBuilder.maxCardsPerShelf, shelf.id)
            XCTAssertEqual(Set(shelf.cardIds).count, shelf.cardIds.count, "\(shelf.id) repeats a card")
            XCTAssertTrue(shelf.cardIds.allSatisfy { !dismissed.contains($0) }, shelf.id)
            XCTAssertTrue(shelf.cardIds.allSatisfy { !tasteIds.contains($0) },
                          "\(shelf.id) recommends something already owned or wanted")
            if let ceiling {
                for id in shelf.cardIds {
                    if let price = prices[id] {
                        XCTAssertLessThan(price, ceiling, "\(shelf.kind.rawValue) leaked \(id)")
                    }
                }
            }
        }

        // ⚠️ The check that catches an alphabetically-truncated candidate window: a real catalog
        // spans hundreds of sets, so shelves drawn from it must not all come from one corner.
        XCTAssertGreaterThan(distinctSets.count, 10,
                             "shelves collapsed onto a handful of sets — check every LIMIT's ORDER BY")

        // The band must actually bite. If nearly everything passes it, it is decorative — which is
        // exactly what the first build of this feature measured as.
        if let band {
            let priced = shelves.filter { $0.kind != .setGoal }.flatMap(\.cardIds).compactMap { prices[$0] }
            let inBand = priced.filter { $0 >= band.p25 && $0 <= band.p75 }.count
            print("in-band (excluding goal shelves): \(inBand)/\(priced.count)")
            XCTAssertGreaterThan(Double(inBand) / Double(max(priced.count, 1)), 0.5,
                                 "most of what For You shows should sit in the buying range")
        }
    }
}
