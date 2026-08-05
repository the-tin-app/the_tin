import Foundation
import Observation

@MainActor @Observable
final class DiscoverModel {
    /// The three endless streams the home surfaces as preview rows + "See all" destinations.
    enum StreamKind: Hashable, CaseIterable {
        case forYou, fullArt, chase
        var title: String {
            switch self {
            case .forYou: return "For You"
            case .fullArt: return "Full-art"
            case .chase: return "Chase"
            }
        }
    }

    /// Number of cards kept per preview row on the home.
    static let previewCount = 10

    private(set) var connections: [Connection] = []
    private(set) var previews: [StreamKind: [CardRecord]] = [:]
    private(set) var isLoaded = false

    /// Taste state, recomputed on every signal change and reused by `makeStream` on the main actor.
    private(set) var profile = DiscoverAffinity.Profile()
    private(set) var tasteIds: Set<String> = []
    /// Average USD price of the user's taste cards — the reference for "cheaper / pricier" captions.
    private(set) var referencePrice: Double?
    /// The user's buying range, from `pricePaid` and wishlist targets. `nil` until there is enough.
    private(set) var band: PriceBand?
    /// `profile.species` widened into families and co-occurring partners.
    private(set) var relatedSpecies: [Int: Double] = [:]
    /// Identical-art reprints of wishlist cards.
    private(set) var twinIds: Set<String> = []
    /// Cards the user thumbed down.
    private(set) var dismissed: Set<String> = []
    /// Derived from "Too expensive" answers; cards at or above it are excluded outright.
    private(set) var priceCeiling: Double?

    /// Per-session shuffle seed for the Full-art stream. Fresh each launch so the shuffle feels new;
    /// stable within a session so paging stays deterministic. Runtime randomness is intentional here.
    let seed: UInt64
    let store: CatalogStore

    /// Last taste signal we assembled for; a change in either count triggers a full rebuild.
    private var lastSignal: (owned: Int, wanted: Int)?

    init(store: CatalogStore) {
        self.store = store
        self.seed = UInt64.random(in: .min ... .max)
    }

    /// The "why" caption shown under a card in the immersive deck: the ForYou experiment tag,
    /// a formatted chase price, or the full-art rarity. `nil` collapses the caption line.
    func caption(for card: CardRecord, kind: StreamKind) -> String? {
        switch kind {
        case .forYou:
            let dexIds: [Int] = ((try? store.dexIds(forCards: [card.id])) ?? [:])[card.id] ?? []
            let names: [Int: String] = (try? store.pokemonNames(dexIds: dexIds)) ?? [:]
            let price: Double? = (try? store.price(cardId: card.id))?.rawUsd
            return DiscoverAffinity.forYouReason(card: card, cardDexIds: dexIds, speciesNames: names,
                                                 profile: profile, priceUsd: price, referencePrice: referencePrice)
        case .chase:
            guard let usd = (try? store.price(cardId: card.id))?.rawUsd else { return nil }
            return "Chase · " + usd.formatted(.currency(code: "USD"))
        case .fullArt:
            return card.rarity
        }
    }

    /// Reconstruct a stream on the main actor from the stored taste `profile`, `tasteIds`, and `seed`.
    /// ForYou/Chase ignore the seed; FullArt uses it for its per-session shuffle. Cheap value-type init.
    func makeStream(_ kind: StreamKind) -> CardStream {
        DiscoverModel.makeStream(kind, store: store, profile: profile, tasteIds: tasteIds, seed: seed,
                                 band: band, relatedSpecies: relatedSpecies, twinIds: twinIds,
                                 dismissed: dismissed, priceCeiling: priceCeiling)
    }

    /// Single source of truth for stream construction, shared by the off-main `assemble` (preview
    /// computation) and the main-actor instance `makeStream(_:)` (StreamView deck). Keeping one
    /// factory prevents preview vs. deck from silently diverging. ForYou/Chase ignore the seed;
    /// FullArt uses it for its per-session shuffle. Cheap value-type inits.
    nonisolated static func makeStream(_ kind: StreamKind, store: CatalogStore,
                                       profile: DiscoverAffinity.Profile, tasteIds: Set<String>,
                                       seed: UInt64, band: PriceBand? = nil,
                                       relatedSpecies: [Int: Double] = [:],
                                       twinIds: Set<String> = [],
                                       dismissed: Set<String> = [],
                                       priceCeiling: Double? = nil) -> CardStream {
        switch kind {
        case .forYou:
            return ForYouStream(store: store, profile: profile, tasteIds: tasteIds,
                                band: band, twinIds: twinIds, dismissed: dismissed,
                                priceCeiling: priceCeiling, relatedSpecies: relatedSpecies)
        case .fullArt: return FullArtStream(store: store, seed: seed)
        case .chase: return ChaseStream(store: store)
        }
    }

    /// Rebuild `profile`, `connections`, and `previews` whenever the taste signal (owned/wanted counts)
    /// changes. No latch: later Want toggles re-run the assembly. All catalog-touching work runs off the
    /// main thread in a detached task; results are assigned back on the main actor.
    func load(entries: [CollectionEntry], wants: [String: WantEntry],
              dismissed: Set<String> = [], reasons: [String: DismissReason] = [:]) async {
        // ⚠️ The dismissed COUNT is part of the signal. Without it a thumbs-down changes neither
        // the owned nor the wanted count, the early return fires, and nothing recomputes.
        let signal = (owned: entries.count, wanted: wants.count + dismissed.count + reasons.count)
        if isLoaded, let last = lastSignal, last == signal { return }

        let store = self.store
        let seed = self.seed
        let assembled = await Task.detached(priority: .userInitiated) {
            DiscoverModel.assemble(store: store, seed: seed, entries: entries, wants: wants,
                                   dismissed: dismissed, reasons: reasons)
        }.value

        profile = assembled.profile
        tasteIds = assembled.tasteIds
        referencePrice = assembled.referencePrice
        band = assembled.band
        relatedSpecies = assembled.relatedSpecies
        twinIds = assembled.twinIds
        self.dismissed = assembled.dismissed
        priceCeiling = assembled.priceCeiling
        connections = assembled.connections
        previews = Self.keepingRejectedInPlace(new: assembled.previews, old: previews,
                                               dismissed: dismissed)
        isLoaded = true
        lastSignal = signal
    }

    /// Re-insert a just-rejected card at the slot it already occupied.
    ///
    /// ⚠️ Without this the thumbs-down is invisible as feedback. Rejecting a card excludes it from
    /// the pool, so the row recomputed and the tile simply **vanished from under the finger** — the
    /// signal was captured and the UI said nothing, which reads as "that did nothing". The card now
    /// holds its place wearing `DismissConfirmedOverlay`, and is gone the next time the row is built
    /// from scratch.
    ///
    /// Only cards that were ALREADY on screen come back; a rejected card never reappears somewhere
    /// new, and the row never grows.
    /// `nonisolated` because it is pure — it reads nothing off the model, so it does not need the
    /// main actor and stays directly unit-testable.
    nonisolated static func keepingRejectedInPlace(new: [StreamKind: [CardRecord]],
                                                   old: [StreamKind: [CardRecord]],
                                                   dismissed: Set<String>) -> [StreamKind: [CardRecord]] {
        guard !dismissed.isEmpty, !old.isEmpty else { return new }
        var out = new
        for (kind, previous) in old {
            let fresh = new[kind] ?? []
            guard !fresh.isEmpty else { continue }
            var merged = fresh
            var freshIds = Set(fresh.map(\.id))
            for (index, card) in previous.enumerated()
            where dismissed.contains(card.id) && !freshIds.contains(card.id) {
                merged.insert(card, at: min(index, merged.count))
                freshIds.insert(card.id)
            }
            out[kind] = Array(merged.prefix(max(previous.count, fresh.count)))
        }
        return out
    }

    /// Sendable bundle of everything the detached assembly computes.
    private struct Assembled: Sendable {
        var profile: DiscoverAffinity.Profile
        var tasteIds: Set<String>
        var referencePrice: Double?
        var band: PriceBand?
        var relatedSpecies: [Int: Double]
        var twinIds: Set<String>
        var dismissed: Set<String>
        var priceCeiling: Double?
        var connections: [Connection]
        var previews: [StreamKind: [CardRecord]]
    }

    /// Bounded, off-main assembly. Builds the taste profile, the connections list, and a page(0)
    /// preview per stream. The stream structs are Sendable value types constructed here purely to
    /// compute previews; the main actor reconstructs them via `makeStream` from the same stored state.
    nonisolated private static func assemble(store: CatalogStore, seed: UInt64,
                                             entries: [CollectionEntry],
                                             wants: [String: WantEntry],
                                             dismissed: Set<String>,
                                             reasons: [String: DismissReason]) -> Assembled {
        let ownedIds = entries.map(\.cardId)
        let wantedIds = Set(wants.keys)
        let tasteIds = Set(ownedIds).union(wantedIds)
        let ownedCards = (try? store.cards(ids: ownedIds)) ?? []
        let wantedCards = (try? store.cards(ids: Array(wantedIds))) ?? []
        let tasteDex = (try? store.dexIds(forCards: Array(tasteIds))) ?? [:]
        let priorities = wants.mapValues(\.priority)
        var profile = DiscoverAffinity.profile(owned: ownedCards, wanted: wantedCards,
                                               dexIds: tasteDex, priorities: priorities)

        var priceCeiling: Double?
        var band = PriceBand.make(entries: entries, wants: wants, now: Date())

        // Stated reasons are applied AFTER the profile is built and normalized. Re-normalizing
        // afterwards would cancel them out — see `DiscoverFeedback.apply`.
        if !reasons.isEmpty {
            let ids = Array(reasons.keys)
            let rejected = Dictionary(uniqueKeysWithValues: ((try? store.cards(ids: ids)) ?? []).map { ($0.id, $0) })
            let rejectedDex = (try? store.dexIds(forCards: ids)) ?? [:]
            let rejectedPrices = ((try? store.prices(cardIds: ids)) ?? [:]).compactMapValues(\.rawUsd)
            let feedback = DiscoverFeedback.derive(reasons: reasons, cards: rejected,
                                                   dexIds: rejectedDex, prices: rejectedPrices)
            profile = feedback.apply(to: profile)
            band = feedback.apply(to: band)
            priceCeiling = feedback.priceCeiling
        }
        let coOccurring = (try? store.coOccurringDexIds(with: Array(profile.species.keys))) ?? []
        let relatedSpecies = DiscoverAffinity.relatedSpecies(seed: profile.species,
                                                            coOccurring: coOccurring)
        // Twins of WANTED cards only — an identical-art reprint of something you already own is
        // a duplicate, not a recommendation.
        var twinIds: Set<String> = []
        for id in wantedIds { twinIds.formUnion((try? store.twins(cardId: id)) ?? []) }
        twinIds.subtract(tasteIds)

        // Reference price = average USD of the user's taste cards (nil when none are priced).
        let tastePrices = ((try? store.prices(cardIds: Array(tasteIds))) ?? [:]).values.compactMap(\.rawUsd)
        let referencePrice: Double? = tastePrices.isEmpty ? nil : tastePrices.reduce(0, +) / Double(tastePrices.count)

        let connections = ConnectionsBuilder.build(store: store)

        var previews: [StreamKind: [CardRecord]] = [:]
        for kind in StreamKind.allCases {
            let stream = makeStream(kind, store: store, profile: profile, tasteIds: tasteIds,
                                    seed: seed, band: band, relatedSpecies: relatedSpecies,
                                    twinIds: twinIds, dismissed: dismissed, priceCeiling: priceCeiling)
            previews[kind] = Array(stream.page(0).prefix(previewCount))
        }

        return Assembled(profile: profile, tasteIds: tasteIds, referencePrice: referencePrice,
                         band: band, relatedSpecies: relatedSpecies, twinIds: twinIds,
                         dismissed: dismissed, priceCeiling: priceCeiling,
                         connections: connections, previews: previews)
    }
}
