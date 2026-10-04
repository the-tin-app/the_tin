import Foundation

/// A species' evolution family, earliest stage first — "Abra → Kadabra → Alakazam" (#197).
///
/// The catalog carries no species-level evolution table; what it has is the line every Pokémon
/// card prints, "Evolves from Kadabra" (`CardDetail.evolveFrom`). So the line is read back out of
/// the cards themselves, one hop at a time, through `Lookup` — which keeps the walk testable
/// without a catalog.
struct EvolutionLine: Equatable {
    /// Earliest first. A stage holds more than one species where the line branches after the
    /// current one (Eevee → eight; Gloom → Vileplume and Bellossom). Stages before the current
    /// species are the single path that led to it.
    let stages: [[PokemonRecord]]
    /// The species the card on screen is.
    let current: Int
}

enum Evolution {
    /// Hops each way. No line is longer than three stages, so two hops from any stage reach both
    /// ends of it.
    static let maxHops = 2

    struct Lookup {
        var species: (Int) -> PokemonRecord?
        /// The species this one evolves from, if its cards say.
        var evolvesFrom: (Int) -> PokemonRecord?
        /// Species whose cards say they evolve from this one.
        var evolvesInto: (Int) -> [PokemonRecord]
    }

    /// nil when there is nothing to draw: a species that neither evolves nor evolves from anything,
    /// or one the catalog doesn't know.
    static func line(for dexId: Int, lookup: Lookup) -> EvolutionLine? {
        guard let current = lookup.species(dexId) else { return nil }
        // `seen` guards every hop: a misprinted or self-referencing "Evolves from" must not loop,
        // and a species must not appear twice in its own line.
        var seen: Set<Int> = [dexId]

        var before: [PokemonRecord] = []
        var cursor = dexId
        for _ in 0..<maxHops {
            guard let previous = lookup.evolvesFrom(cursor), seen.insert(previous.dexId).inserted else { break }
            before.insert(previous, at: 0)
            cursor = previous.dexId
        }

        var after: [[PokemonRecord]] = []
        var frontier = [dexId]
        for _ in 0..<maxHops {
            let next = frontier.flatMap(lookup.evolvesInto)
                .filter { seen.insert($0.dexId).inserted }
                .sorted { $0.dexId < $1.dexId }
            guard !next.isEmpty else { break }
            after.append(next)
            frontier = next.map(\.dexId)
        }

        guard !before.isEmpty || !after.isEmpty else { return nil }
        return EvolutionLine(stages: before.map { [$0] } + [[current]] + after, current: dexId)
    }
}
