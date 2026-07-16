import Foundation

/// Endless "random" browse of full-art (SIR/IR/secret) cards. The candidate set is shuffled
/// once with a per-session seed (deterministic), then paged. `seed` varies per app launch so
/// each session feels fresh; within a session paging is stable.
struct FullArtStream: CardStream {
    let store: CatalogStore
    let seed: UInt64
    var pageSize: Int = 15

    private var shuffled: [CardRecord] {
        var rng = SeededRNG(seed: seed)
        var cards = (try? store.cards(matchingRarities: DiscoverConstants.fullArtRarities)) ?? []
        cards.shuffle(using: &rng)
        return cards
    }

    func page(_ index: Int) -> [CardRecord] {
        let all = shuffled
        let start = index * pageSize
        guard start < all.count else { return [] }
        return Array(all[start..<min(start + pageSize, all.count)])
    }
}

/// Small deterministic RNG (SplitMix64) so shuffles are reproducible from a seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
