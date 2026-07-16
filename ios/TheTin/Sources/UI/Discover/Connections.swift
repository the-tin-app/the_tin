import Foundation

/// A named group of cards that "belong together": a curated art scene / story arc,
/// or an auto-derived artist spotlight / gallery subset.
struct Connection: Identifiable, Equatable {
    enum Kind: String { case combinedArt, narrative, artistSpotlight, gallery }
    let id: String
    let kind: Kind
    let title: String
    let cardIds: [String]
}

enum ConnectionsBuilder {
    /// Assemble all v1 connections. Curated first (combined + narrative), then auto
    /// artist spotlights and gallery subsets. Pure aggregation over CatalogStore reads.
    static func build(store: CatalogStore, artistLimit: Int = 8) -> [Connection] {
        var out: [Connection] = []

        for c in (try? store.curatedConnections()) ?? [] {
            let kind: Connection.Kind = (c.kind == "narrative") ? .narrative : .combinedArt
            out.append(Connection(id: c.id, kind: kind, title: c.title, cardIds: c.cardIds))
        }

        for artist in (try? store.topArtists(limit: artistLimit)) ?? [] {
            let cards = (try? store.cards(byArtist: artist)) ?? []
            guard cards.count >= 2 else { continue }
            out.append(Connection(id: "artist/\(artist)", kind: .artistSpotlight,
                                   title: "More from \(artist)", cardIds: cards.map(\.id)))
        }

        for (key, cards) in (try? store.galleryCards()) ?? [:] where cards.count >= 2 {
            out.append(Connection(id: "gallery/\(key)", kind: .gallery,
                                  title: "Gallery · \(cards.first?.setId ?? key)",
                                  cardIds: cards.map(\.id)))
        }

        return out
    }
}
