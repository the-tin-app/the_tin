import Foundation

/// Personalized endless stream. Each page: ~80% taste-ranked matches from progressively wider
/// affinity buckets, ~20% "experiments" (same artist/set, one tier cheaper/pricier). Empty
/// profile falls back to a popular/high-value mix so cold-start users always have cards.
struct ForYouStream: CardStream {
    let store: CatalogStore
    let profile: DiscoverAffinity.Profile
    let tasteIds: Set<String>
    var pageSize: Int = 12

    /// Buckets considered per dimension grow with the page index (progressive widening).
    static func bucketDepth(forPage index: Int) -> Int { 4 + index * 4 }
    /// Roughly one in `varietyEvery` cards is an interleaved variety pick (full-art / chase),
    /// so a run of same-taste matches never goes unbroken.
    static let varietyEvery = 4
    static func experimentSlots(pageSize: Int) -> Int { max(1, pageSize / varietyEvery) }

    func page(_ index: Int) -> [CardRecord] {
        guard !profile.isEmpty else { return popularMix(index) }

        let depth = Self.bucketDepth(forPage: index)
        let topSets: [String] = profile.sets.sorted { $0.value > $1.value }.prefix(depth).map(\.key)
        let topSpecies: [Int] = profile.species.sorted { $0.value > $1.value }.prefix(depth).map(\.key)
        let topArtists: [String] = profile.artists.sorted { $0.value > $1.value }.prefix(depth).map(\.key)

        var pool: [String: CardRecord] = [:]
        for s in topSets {
            let cards: [CardRecord] = (try? store.cards(inSet: s)) ?? []
            for c in cards { pool[c.id] = c }
        }
        for d in topSpecies {
            let cards: [CardRecord] = (try? store.cards(forDex: d)) ?? []
            for c in cards { pool[c.id] = c }
        }
        for a in topArtists {
            let cards: [CardRecord] = (try? store.cards(byArtist: a)) ?? []
            for c in cards { pool[c.id] = c }
        }
        for id in tasteIds { pool[id] = nil }

        let poolDex: [String: [Int]] = (try? store.dexIds(forCards: Array(pool.keys))) ?? [:]
        let rankLimit: Int = pageSize * (index + 1)
        let ranked: [CardRecord] = DiscoverAffinity.rank(candidates: Array(pool.values), dexIds: poolDex,
                                                          profile: profile, limit: rankLimit)
        // Reserve ~1-in-varietyEvery slots for interleaved variety so taste-matches never run unbroken.
        let varietyCount: Int = Self.experimentSlots(pageSize: pageSize)
        let matchCount: Int = pageSize - varietyCount
        let start: Int = index * matchCount
        let matches: [CardRecord] = Array(ranked.dropFirst(start).prefix(matchCount))
        let used: Set<String> = tasteIds.union(matches.map(\.id))
        let variety: [CardRecord] = varietyPicks(count: varietyCount, page: index, exclude: used)
        return Self.interleave(matches: matches, variety: variety, every: Self.varietyEvery)
    }

    /// Deliberate discovery picks pulled from OUTSIDE the taste pool: full-art (SIR/IR) and chase
    /// (top-priced) cards, alternating. Deterministic per page (cursor offset by `page`), so paging
    /// stays reproducible; `StreamPager` dedups any cross-page repeats.
    private func varietyPicks(count: Int, page: Int, exclude: Set<String>) -> [CardRecord] {
        let fullArt: [CardRecord] = (try? store.cards(matchingRarities: DiscoverConstants.fullArtRarities)) ?? []
        let chase: [CardRecord] = (try? store.topPricedCards(offset: 0, limit: 300)) ?? []
        var faIdx = page, chIdx = page
        var used = exclude
        var picks: [CardRecord] = []
        func next(_ pool: [CardRecord], _ idx: inout Int) -> CardRecord? {
            while idx < pool.count {
                let c = pool[idx]; idx += 1
                if used.insert(c.id).inserted { return c }
            }
            return nil
        }
        for i in 0..<count {
            let pick: CardRecord? = ((i + page) % 2 == 0)
                ? (next(fullArt, &faIdx) ?? next(chase, &chIdx))
                : (next(chase, &chIdx) ?? next(fullArt, &faIdx))
            if let pick { picks.append(pick) }
        }
        return picks
    }

    /// Weave `variety` into `matches`, placing a variety card every `every`-th slot; trailing
    /// leftovers of either list are appended in order.
    static func interleave(matches: [CardRecord], variety: [CardRecord], every: Int) -> [CardRecord] {
        var result: [CardRecord] = []
        var mi = 0, vi = 0, pos = 0
        while mi < matches.count || vi < variety.count {
            if pos % every == every - 1, vi < variety.count {
                result.append(variety[vi]); vi += 1
            } else if mi < matches.count {
                result.append(matches[mi]); mi += 1
            } else if vi < variety.count {
                result.append(variety[vi]); vi += 1
            }
            pos += 1
        }
        return result
    }

    /// Cold-start: blend high-value + full-art standouts.
    private func popularMix(_ index: Int) -> [CardRecord] {
        let chase: [CardRecord] = (try? store.topPricedCards(offset: index * pageSize, limit: pageSize)) ?? []
        if !chase.isEmpty { return chase }
        let art: [CardRecord] = (try? store.cards(matchingRarities: DiscoverConstants.fullArtRarities)) ?? []
        let start = index * pageSize
        guard start < art.count else { return [] }
        return Array(art[start..<min(start + pageSize, art.count)])
    }
}
