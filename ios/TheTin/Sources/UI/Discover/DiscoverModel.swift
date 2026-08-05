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
    /// The built shelves, in priority order. `ForYouStream` round-robins them for the home strip;
    /// `ForYouShelvesView` renders them as rows.
    private(set) var shelves: [Shelf] = []
    /// The user's buying range. `nil` until there is enough purchase or target history for one.
    private(set) var band: PriceBand?

    /// Per-session shuffle seed for the Full-art stream. Fresh each launch so the shuffle feels new;
    /// stable within a session so paging stays deterministic. Runtime randomness is intentional here.
    let seed: UInt64
    let store: CatalogStore

    /// What we last assembled for. Comparing the whole input value rather than a pair of counts is
    /// what lets a dismissal, a reason, or a new set goal trigger a rebuild — none of those change
    /// the owned or wanted count, so the old `(owned, wanted)` signal could not see them at all.
    private var lastInputs: Inputs?

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

    /// Reconstruct a stream on the main actor from the stored state.
    /// ForYou reads the built shelves; FullArt uses the seed for its per-session shuffle.
    func makeStream(_ kind: StreamKind) -> CardStream {
        DiscoverModel.makeStream(kind, store: store, shelves: shelves, seed: seed)
    }

    /// The deck behind one shelf's "See all" — the same immersive `StreamView`, over one row.
    func makeStream(for shelf: Shelf) -> CardStream {
        ShelfStream(store: store, shelf: shelf)
    }

    /// Single source of truth for stream construction, shared by the off-main `assemble` (preview
    /// computation) and the main-actor instance `makeStream(_:)` (StreamView deck). Keeping one
    /// factory prevents preview vs. deck from silently diverging.
    nonisolated static func makeStream(_ kind: StreamKind, store: CatalogStore,
                                       shelves: [Shelf], seed: UInt64) -> CardStream {
        switch kind {
        case .forYou: return ForYouStream(store: store, shelves: shelves)
        case .fullArt: return FullArtStream(store: store, seed: seed)
        case .chase: return ChaseStream(store: store)
        }
    }

    /// Everything the assembly needs that lives outside the catalog. Grouped into one Sendable value
    /// rather than eight parameters, because `load` and `assemble` both take all of it.
    struct Inputs: Sendable, Equatable {
        var entries: [CollectionEntry] = []
        var wants: [String: WantEntry] = [:]
        var setGoals: Set<String> = []
        var dismissed: Set<String> = []
        var reasons: [String: DismissReason] = [:]
        /// Bumped by `DiscoverSignalsModel` on every write. Load-bearing: a thumbs-down changes
        /// neither the owned nor the wanted count, so without it the recommendations would not
        /// recompute until the user happened to add or heart something.
        var signalsRevision: Int = 0

        var ownedIds: [String] { entries.map(\.cardId) }
    }

    /// Rebuild the profile, band, shelves, connections and previews whenever any input changes.
    /// All catalog-touching work runs off the main thread; results are assigned back on the main actor.
    func load(_ inputs: Inputs) async {
        if isLoaded, lastInputs == inputs { return }

        let store = self.store
        let seed = self.seed
        let assembled = await Task.detached(priority: .userInitiated) {
            DiscoverModel.assemble(store: store, seed: seed, inputs: inputs)
        }.value

        profile = assembled.profile
        tasteIds = assembled.tasteIds
        referencePrice = assembled.referencePrice
        band = assembled.band
        shelves = assembled.shelves
        connections = assembled.connections
        previews = assembled.previews
        isLoaded = true
        lastInputs = inputs
    }

    /// Sendable bundle of everything the detached assembly computes.
    private struct Assembled: Sendable {
        var profile: DiscoverAffinity.Profile
        var tasteIds: Set<String>
        var referencePrice: Double?
        var band: PriceBand?
        var shelves: [Shelf]
        var connections: [Connection]
        var previews: [StreamKind: [CardRecord]]
    }

    /// Bounded, off-main assembly.
    nonisolated private static func assemble(store: CatalogStore, seed: UInt64,
                                             inputs: Inputs) -> Assembled {
        let ownedIds = inputs.ownedIds
        let wantedIds = Set(inputs.wants.keys)
        let tasteIds = Set(ownedIds).union(wantedIds)
        let ownedCards = (try? store.cards(ids: ownedIds)) ?? []
        let wantedCards = (try? store.cards(ids: Array(wantedIds))) ?? []
        let tasteDex = (try? store.dexIds(forCards: Array(tasteIds))) ?? [:]
        var profile = DiscoverAffinity.profile(owned: ownedCards, wanted: wantedCards,
                                               dexIds: tasteDex,
                                               priorities: inputs.wants.mapValues(\.priority))

        var band = PriceBand.make(entries: inputs.entries, wants: inputs.wants, now: Date())
        var priceCeiling: Double?

        // Stated reasons are applied AFTER the profile is built and normalized. Re-normalizing
        // afterwards would cancel them out — see `DiscoverFeedback.apply`.
        if !inputs.reasons.isEmpty {
            let ids = Array(inputs.reasons.keys)
            let rejected = Dictionary(uniqueKeysWithValues: ((try? store.cards(ids: ids)) ?? []).map { ($0.id, $0) })
            let feedback = DiscoverFeedback.derive(
                reasons: inputs.reasons, cards: rejected,
                dexIds: (try? store.dexIds(forCards: ids)) ?? [:],
                prices: ((try? store.prices(cardIds: ids)) ?? [:]).compactMapValues(\.rawUsd))
            profile = feedback.apply(to: profile)
            band = feedback.apply(to: band)
            priceCeiling = feedback.priceCeiling
        }

        let coOccurring = (try? store.coOccurringDexIds(with: Array(profile.species.keys))) ?? []
        let relatedSpecies = DiscoverAffinity.relatedSpecies(seed: profile.species,
                                                            coOccurring: coOccurring)

        let shelves = ShelfBuilder.build(store: store, profile: profile, band: band,
                                         setGoals: inputs.setGoals, owned: Set(ownedIds),
                                         tasteIds: tasteIds, dismissed: inputs.dismissed,
                                         priceCeiling: priceCeiling, relatedSpecies: relatedSpecies)

        // Reference price = average USD of the user's taste cards (nil when none are priced).
        let tastePrices = ((try? store.prices(cardIds: Array(tasteIds))) ?? [:]).values.compactMap(\.rawUsd)
        let referencePrice: Double? = tastePrices.isEmpty ? nil : tastePrices.reduce(0, +) / Double(tastePrices.count)

        let connections = ConnectionsBuilder.build(store: store)

        var previews: [StreamKind: [CardRecord]] = [:]
        for kind in StreamKind.allCases {
            let stream = makeStream(kind, store: store, shelves: shelves, seed: seed)
            previews[kind] = Array(stream.page(0).prefix(previewCount))
        }

        return Assembled(profile: profile, tasteIds: tasteIds, referencePrice: referencePrice,
                         band: band, shelves: shelves, connections: connections, previews: previews)
    }
}
