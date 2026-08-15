import Foundation

/// Builds the public share/deep-link URL for a card:
/// `https://thetinapp.com/c/<id>?n=<name>&set=<set>&img=<high-res image url>`.
/// The query carries display data so the web preview (Cloudflare Pages Function at /c/:id)
/// can render Open Graph tags without any catalog lookup. Universal Links route /c/* back
/// into the app; see `AppModel.handleDeepLink`.
enum CardShareLink {
    static let host = "thetinapp.com"

    /// Stand-in for a list link that hasn't been built yet. Exists so a `ShareLink` never has to
    /// be conditionally PRESENT — an absent toolbar item leaves a zero-size placeholder that the
    /// iPad share popover then anchors to, which is what broke sharing on iPad entirely. The
    /// button is disabled while this is what it holds, so it is never actually shared.
    static let homeURL = URL(string: "https://\(host)")!

    static func url(card: CardRecord, setName: String?) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/c/\(card.id)"
        var items = [URLQueryItem(name: "n", value: card.name)]
        if let setName { items.append(URLQueryItem(name: "set", value: setName)) }
        // See `CardRecord.webArtURL` for why this isn't `imageURL(quality:)`. It used to be
        // inlined here as imageBase-then-imageUrl, which SKIPPED the TCGplayer-CDN branch — a card
        // TCGdex has no art for shared with no preview image at all.
        if let art = card.webArtURL { items.append(URLQueryItem(name: "img", value: art.absoluteString)) }
        c.queryItems = items
        // Components are all app-constructed from known-safe pieces; a nil url here is a
        // programming error, not user input.
        return c.url!
    }
}
