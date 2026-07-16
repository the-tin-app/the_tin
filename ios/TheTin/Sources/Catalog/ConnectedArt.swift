import Foundation

/// A curated "connected art" scene: a set of cards whose illustrations form one continuous
/// artwork. Backed by the shipped `connected_art` table; cards are in `position` order.
struct ConnectedArtScene: Identifiable, Equatable {
    let sceneId: String
    let title: String
    let cardIds: [String]
    var id: String { sceneId }
}
