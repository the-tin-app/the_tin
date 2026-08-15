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
    /// Cards kept per connection. The Connections row is a preview strip rendered in a plain
    /// `HStack` — non-lazy, so every tile it holds is built and starts loading its art at once.
    /// `topArtists` returns the most PROLIFIC illustrators, so an uncapped artist spotlight was
    /// several hundred tiles, and eight of them materialising during a fast scroll took the app
    /// out with an untraceable jetsam kill (SIGKILL never reaches Crashlytics).
    static let maxCardsPerConnection = 10

    /// Assemble all v1 connections. Curated first (combined + narrative), then auto
    /// artist spotlights and gallery subsets. Pure aggregation over CatalogStore reads.
    static func build(store: CatalogStore, artistLimit: Int = 8,
                      maxCards: Int = maxCardsPerConnection) -> [Connection] {
        var out: [Connection] = []

        for c in (try? store.curatedConnections()) ?? [] {
            let kind: Connection.Kind = (c.kind == "narrative") ? .narrative : .combinedArt
            out.append(Connection(id: c.id, kind: kind, title: c.title,
                                  cardIds: Array(c.cardIds.prefix(maxCards))))
        }

        for artist in (try? store.topArtists(limit: artistLimit)) ?? [] {
            let cards = (try? store.cards(byArtist: artist)) ?? []
            guard cards.count >= 2 else { continue }
            out.append(Connection(id: "artist/\(artist)", kind: .artistSpotlight,
                                   title: "More from \(artist)",
                                   cardIds: cards.prefix(maxCards).map(\.id)))
        }

        for (key, cards) in (try? store.galleryCards()) ?? [:] where cards.count >= 2 {
            out.append(Connection(id: "gallery/\(key)", kind: .gallery,
                                  title: "Gallery · \(cards.first?.setId ?? key)",
                                  cardIds: cards.prefix(maxCards).map(\.id)))
        }

        return out
    }
}
