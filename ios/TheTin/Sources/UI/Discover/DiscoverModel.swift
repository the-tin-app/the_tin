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
        DiscoverModel.makeStream(kind, store: store, profile: profile, tasteIds: tasteIds, seed: seed)
    }

    /// Single source of truth for stream construction, shared by the off-main `assemble` (preview
    /// computation) and the main-actor instance `makeStream(_:)` (StreamView deck). Keeping one
    /// factory prevents preview vs. deck from silently diverging. ForYou/Chase ignore the seed;
    /// FullArt uses it for its per-session shuffle. Cheap value-type inits.
    nonisolated static func makeStream(_ kind: StreamKind, store: CatalogStore,
                                       profile: DiscoverAffinity.Profile, tasteIds: Set<String>,
                                       seed: UInt64) -> CardStream {
        switch kind {
        case .forYou: return ForYouStream(store: store, profile: profile, tasteIds: tasteIds)
        case .fullArt: return FullArtStream(store: store, seed: seed)
        case .chase: return ChaseStream(store: store)
        }
    }

    /// Rebuild `profile`, `connections`, and `previews` whenever the taste signal (owned/wanted counts)
    /// changes. No latch: later Want toggles re-run the assembly. All catalog-touching work runs off the
    /// main thread in a detached task; results are assigned back on the main actor.
    func load(ownedIds: [String], wantedIds: Set<String>) async {
        let signal = (owned: ownedIds.count, wanted: wantedIds.count)
        if isLoaded, let last = lastSignal, last == signal { return }

        let store = self.store
        let seed = self.seed
        let assembled = await Task.detached(priority: .userInitiated) {
            DiscoverModel.assemble(store: store, seed: seed, ownedIds: ownedIds, wantedIds: wantedIds)
        }.value

        profile = assembled.profile
        tasteIds = assembled.tasteIds
        referencePrice = assembled.referencePrice
        connections = assembled.connections
        previews = assembled.previews
        isLoaded = true
        lastSignal = signal
    }

    /// Sendable bundle of everything the detached assembly computes.
    private struct Assembled: Sendable {
        var profile: DiscoverAffinity.Profile
        var tasteIds: Set<String>
        var referencePrice: Double?
        var connections: [Connection]
        var previews: [StreamKind: [CardRecord]]
    }

    /// Bounded, off-main assembly. Builds the taste profile, the connections list, and a page(0)
    /// preview per stream. The stream structs are Sendable value types constructed here purely to
    /// compute previews; the main actor reconstructs them via `makeStream` from the same stored state.
    nonisolated private static func assemble(store: CatalogStore, seed: UInt64,
                                             ownedIds: [String], wantedIds: Set<String>) -> Assembled {
        let tasteIds = Set(ownedIds).union(wantedIds)
        let ownedCards = (try? store.cards(ids: ownedIds)) ?? []
        let wantedCards = (try? store.cards(ids: Array(wantedIds))) ?? []
        let tasteDex = (try? store.dexIds(forCards: Array(tasteIds))) ?? [:]
        let profile = DiscoverAffinity.profile(owned: ownedCards, wanted: wantedCards, dexIds: tasteDex)

        // Reference price = average USD of the user's taste cards (nil when none are priced).
        let tastePrices = ((try? store.prices(cardIds: Array(tasteIds))) ?? [:]).values.compactMap(\.rawUsd)
        let referencePrice: Double? = tastePrices.isEmpty ? nil : tastePrices.reduce(0, +) / Double(tastePrices.count)

        let connections = ConnectionsBuilder.build(store: store)

        var previews: [StreamKind: [CardRecord]] = [:]
        for kind in StreamKind.allCases {
            let stream = makeStream(kind, store: store, profile: profile, tasteIds: tasteIds, seed: seed)
            previews[kind] = Array(stream.page(0).prefix(previewCount))
        }

        return Assembled(profile: profile, tasteIds: tasteIds, referencePrice: referencePrice,
                         connections: connections, previews: previews)
    }
}
