import Foundation
import OSLog

/// One titled row of For You. The title carries the reason a card is there, which is the whole
/// reason shelves exist: in the previous design the reason was a per-card caption, while the
/// structure that actually decided the deck — `perGroupCap: 3` on set / artist / species — was
/// invisible and unexplainable.
struct Shelf: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case setGoal, band, historicLow, weeklyDrop, species, artist, explore
    }
    let id: String
    let kind: Kind
    /// What this shelf is about — a set name, a species, an artist, a price cap. `nil` where the
    /// reason needs no subject ("Cheapest in 6 months" is about nothing but itself).
    let subject: String?
    /// A shelf-level fact for the row header only ("120 left").
    let detail: String?
    let cardIds: [String]

    /// The row header on the shelves screen.
    var title: String {
        let base: String
        switch kind {
        case .setGoal:     base = subject.map { "Finish \($0)" } ?? "Finish a set you collect"
        case .band:        base = subject.map { "Under \($0) · your usual range" } ?? "Your usual range"
        case .historicLow: base = "Cheapest in 6 months"
        case .weeklyDrop:  base = "Down this week"
        case .species:     base = subject.map { "Because you like \($0)" } ?? "A species you like"
        case .artist:      base = subject.map { "More from \($0)" } ?? "An artist you like"
        case .explore:     base = "Something new"
        }
        return detail.map { "\(base) · \($0)" } ?? base
    }

    /// Why **this card** is in front of you, shown under it in the deck.
    ///
    /// ⚠️ This replaces `DiscoverAffinity.forYouReason`, which answered a different question: it
    /// ranked *properties of the card* (full-art first, then species, then artist, then set) and had
    /// no idea why the card had been chosen. Verified on the simulator against real data, every card
    /// in the round-robin read "✨ Full-art find" — including the two leading it, which were there
    /// because they complete sets the collector is chasing. The card was being described instead of
    /// explained.
    ///
    /// The shelf already knows the answer, so the caption is now a lookup rather than a re-derivation
    /// — which also deletes three synchronous catalog reads per card render on the main actor.
    ///
    /// Shelf-level facts (`detail`) are deliberately dropped: how many cards remain in a set belongs
    /// to the row header, not under the one card in your hand.
    var caption: String {
        switch kind {
        case .setGoal:     return subject.map { "Finishing \($0)" } ?? "Finishing a set you collect"
        case .band:        return "In your usual range"
        case .historicLow: return "Cheapest in 6 months"
        case .weeklyDrop:  return "Down this week"
        case .species:     return subject.map { "Because you like \($0)" } ?? "A species you like"
        case .artist:      return subject.map { "More from \($0)" } ?? "An artist you like"
        case .explore:     return "Something new"
        }
    }
}

/// Pure aggregation over `CatalogStore` reads, following `ConnectionsBuilder`.
///
/// ⚠️ **This is the one seam.** Every card that reaches a user passes through `build`, so the
/// dismissal set, the taste set and the price ceiling are applied exactly once, here.
///
/// The bug it replaces was structural rather than arithmetic: `ForYouStream` applied the ceiling to
/// its candidate *pool* and then appended `varietyPicks` — drawn straight from `topPricedCards` —
/// afterwards. Measured against real device data, a $4,500 card therefore sat at slot 4 of page 0
/// of a deck whose band was $5.13–$33.55, and dismissing it merely promoted the next grail into the
/// same slot, 300 deep. Applying exclusions where every consumer routes through means variety
/// inherits them for free.
enum ShelfBuilder {
    private static let log = Logger(subsystem: "ai.reyes.thetin", category: "ShelfBuilder")

    /// Cards kept per shelf, enforced HERE so every consumer inherits it. Same reasoning as
    /// `ConnectionsBuilder.maxCardsPerConnection`, whose absence took the app out with a jetsam kill
    /// when an uncapped 1,767-card artist spotlight reached a non-lazy `HStack`.
    static let maxCardsPerShelf = 24

    /// Below this a row looks broken rather than curated, and a set-goal shelf widens past the band.
    /// Measured: `me05` yields only 4 in-band cards against a cap of 24.
    static let minCardsPerShelf = 8

    /// How close to its 6-month low a card must be to count as "cheapest in 6 months".
    static let historicLowWithinPct = 0.05

    /// Candidates handed to the band-backed shelves. Bounded because `cardsNearHistoricLow` scans
    /// up to ~26 weekly rows per candidate and the A10 iPad is the canary.
    static let buySignalCandidateLimit = 600

    /// How many species shelves to render at most.
    static let maxSpeciesShelves = 4

    /// How many artist shelves to render at most.
    static let maxArtistShelves = 2

    /// Does this card survive the filters every shelf shares?
    ///
    /// The ceiling is a hard cut, not a multiplier. Measured: the cards a collector rejects are
    /// already far above `band.p75`, so tightening the band changed nothing — and they were already
    /// pinned at the price floor yet still ranked top, because a 3× species match swamps any
    /// multiplier. An unpriced card is neutral, matching `PriceBand.fit`.
    static func admits(price: Double?, priceCeiling: Double?) -> Bool {
        guard let price, let priceCeiling else { return true }
        return price < priceCeiling
    }

    /// Which species get their own shelf: walk by weight, skipping any whose family window overlaps
    /// one already taken.
    ///
    /// ⚠️ Without this, dex-adjacent favourites each produce a near-identical row. Measured on a real
    /// collection, Articuno / Zapdos / Moltres (144/145/146) shared 62–88% of their cards, because
    /// `DiscoverAffinity.adjacencyRadius` is 2 and their windows sit on top of each other.
    static func speciesSeeds(_ species: [Int: Double], limit: Int = maxSpeciesShelves) -> [Int] {
        var taken: [Int] = []
        // Weight desc, then dex id, so ties are deterministic across launches.
        for (dexId, _) in species.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            guard taken.count < limit else { break }
            let overlaps = taken.contains { abs($0 - dexId) <= DiscoverAffinity.adjacencyRadius * 2 }
            if !overlaps { taken.append(dexId) }
        }
        return taken.sorted { lhs, rhs in
            let l = species[lhs] ?? 0, r = species[rhs] ?? 0
            return l != r ? l > r : lhs < rhs
        }
    }

    /// ⚠️ A failed read and an empty result are indistinguishable once "absent when empty" is the
    /// rule — and that is exactly the shape that made `CardDetailModel` look like a catalog problem
    /// for two days, because every read there was `try?` and the empty result got cached. Log the
    /// difference so the next empty screen can be diagnosed rather than guessed at.
    private static func read<T>(_ what: String, _ body: () throws -> [T]) -> [T] {
        do { return try body() } catch {
            log.error("shelf read failed: \(what, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func build(store: CatalogStore,
                      profile: DiscoverAffinity.Profile,
                      band: PriceBand?,
                      setGoals: Set<String>,
                      owned: Set<String>,
                      tasteIds: Set<String>,
                      dismissed: Set<String>,
                      priceCeiling: Double?,
                      relatedSpecies: [Int: Double],
                      maxCards: Int = maxCardsPerShelf) -> [Shelf] {
        var out: [Shelf] = []
        let excluded = tasteIds.union(dismissed)
        var scoringProfile = profile
        if !relatedSpecies.isEmpty { scoringProfile.species = relatedSpecies }

        /// Cards already placed. Shelves are built in priority order, so a card lands under the
        /// strongest reason for showing it and appears exactly once.
        ///
        /// ⚠️ The spec put this dedup in `ForYouStream`'s round-robin, which is not enough: the
        /// stream shows one card at a time, but `ForYouShelvesView` renders every row at once.
        /// Measured on real data, "Because you like Articuno" and "More from 5ban Graphics" led
        /// with the SAME THREE CARDS — two adjacent rows that read as a rendering bug. Deduping in
        /// the builder means both surfaces agree, and it is the same greedy principle as
        /// `speciesSeeds`.
        var used: Set<String> = []

        /// Prices for a candidate set, fetched once and reused by both the seam and the ranking.
        func prices(_ cards: [CardRecord]) -> [String: Double] {
            guard !cards.isEmpty else { return [:] }
            do { return try store.previewPrices(cardIds: cards.map(\.id)) } catch {
                log.error("shelf read failed: previewPrices — \(error.localizedDescription, privacy: .public)")
                return [:]
            }
        }

        /// The seam. Nothing reaches a shelf except through here.
        func admit(_ cards: [CardRecord], _ priced: [String: Double]) -> [CardRecord] {
            cards.filter {
                !excluded.contains($0.id) && !used.contains($0.id)
                    && admits(price: priced[$0.id], priceCeiling: priceCeiling)
            }
        }

        func rank(_ cards: [CardRecord], _ priced: [String: Double]) -> [String] {
            guard !cards.isEmpty else { return [] }
            let dex = read("dexIds") { Array(try store.dexIds(forCards: cards.map(\.id))) }
            let dexById = Dictionary(uniqueKeysWithValues: dex.map { ($0.key, $0.value) })
            return cards
                .map { ($0.id, DiscoverAffinity.score($0, dexIds: dexById[$0.id] ?? [],
                                                      profile: scoringProfile, band: band,
                                                      priceUsd: priced[$0.id])) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(maxCards)
                .map(\.0)
        }

        /// A shelf with no data does NOT render. Not an empty state, not a placeholder — absent,
        /// the rule the Supporters row already follows. Distinct from the Movers case, where a bold
        /// `+$0.00` was a lie about movement; here there is no claim to get wrong.
        func append(_ kind: Shelf.Kind, id: String, subject: String? = nil,
                    detail: String? = nil, cards: [CardRecord]) {
            let priced = prices(cards)
            let ids = rank(admit(cards, priced), priced)
            guard !ids.isEmpty else { return }
            used.formUnion(ids)
            out.append(Shelf(id: id, kind: kind, subject: subject, detail: detail, cardIds: ids))
        }

        // 1. Set goals — the user literally named the set.
        for setId in setGoals.sorted() {
            guard let record = (try? store.set(id: setId)) ?? nil else { continue }
            var cards = read("cardsMissingFromSet(\(setId))") {
                try store.cardsMissingFromSet(setId, owned: owned, band: band, limit: maxCards * 3)
            }
            // ⚠️ In-band alone can starve a goal shelf: `me05` yields 4 cards against a cap of 24.
            // A four-card row reads as broken, so widen to the whole gap and let affinity order it.
            if cards.count < minCardsPerShelf {
                let wider = read("cardsMissingFromSet(\(setId), unbanded)") {
                    try store.cardsMissingFromSet(setId, owned: owned, band: nil, limit: maxCards * 8)
                }
                if !wider.isEmpty { cards = wider }
            }
            let remaining = read("cardsMissingFromSet(\(setId), count)") {
                try store.cardsMissingFromSet(setId, owned: owned, band: nil, limit: Int.max)
            }.count
            append(.setGoal, id: "setGoal/\(setId)", subject: record.name,
                   detail: "\(remaining) left", cards: cards)
        }

        // 2. Buy signals against a stated budget.
        var bandCards: [CardRecord] = []
        if let band {
            bandCards = read("cardsInPriceBand") {
                try store.cardsInPriceBand(band, limit: buySignalCandidateLimit)
            }
            let bandPrices = prices(bandCards)
            let candidates = admit(bandCards, bandPrices)
            let candidateIds = candidates.map(\.id)
            let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

            let lowIds = read("cardsNearHistoricLow") {
                try store.cardsNearHistoricLow(candidateIds: candidateIds,
                                               withinPct: historicLowWithinPct, limit: maxCards * 2)
            }
            append(.historicLow, id: "historicLow", cards: lowIds.compactMap { byId[$0] })

            let drops = read("cardsDroppedThisWeek") {
                try store.cardsDroppedThisWeek(candidateIds: candidateIds,
                                               maxPct: DiscoverConstants.dealsMaxPct7d, limit: maxCards)
            }
            // Already ordered by drop size in SQL, and that ordering IS the reason — don't re-rank.
            // Still passes `used`, so this shelf obeys cross-shelf dedup like every other one.
            let dropIds = Array(drops.compactMap { byId[$0.id]?.id }
                .filter { !used.contains($0) }.prefix(maxCards))
            if !dropIds.isEmpty {
                used.formUnion(dropIds)
                out.append(Shelf(id: "weeklyDrop", kind: .weeklyDrop, subject: nil,
                                 detail: nil, cardIds: dropIds))
            }

            append(.band, id: "band", subject: "$\(Int(band.p75))", cards: bandCards)
        }

        // 3. Inferred similarity.
        let seeds = speciesSeeds(profile.species)
        let seedNames = (try? store.pokemonNames(dexIds: seeds)) ?? [:]
        for seed in seeds {
            guard let name = seedNames[seed] else { continue }
            let radius = DiscoverAffinity.adjacencyRadius
            let family = ((seed - radius)...(seed + radius)).filter {
                $0 > 0 && (profile.species[$0] != nil || relatedSpecies[$0] != nil)
            }
            let cards = read("cardsForDexIds(\(seed))") {
                try store.cardsForDexIds(family, band: band, limit: maxCards * 4)
            }
            append(.species, id: "species/\(seed)", subject: name, cards: cards)
        }

        for artist in profile.artists.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
            .prefix(maxArtistShelves).map(\.key) {
            let cards = read("cardsByArtist(\(artist))") { try store.cards(byArtist: artist) }
            append(.artist, id: "artist/\(artist)", subject: artist, cards: cards)
        }

        // 4. Exploration: a set AND artist never touched — but IN BAND. Novelty comes from the
        //    dimension, never from the price. `varietyPicks` made "something new" mean "something
        //    expensive", which is how a $4,500 card became a recurring recommendation.
        if band != nil {
            let fresh = bandCards.filter {
                profile.sets[$0.setId] == nil && ($0.artist.map { profile.artists[$0] == nil } ?? true)
            }
            append(.explore, id: "explore", cards: fresh)
        }

        return out
    }
}
