import Foundation

/// Builds the public share/deep-link URL for a card:
/// `https://thetinapp.com/c/<id>?n=<name>&set=<set>&img=<high-res image url>`.
/// The query carries display data so the web preview (Cloudflare Pages Function at /c/:id)
/// can render Open Graph tags without any catalog lookup. Universal Links route /c/* back
/// into the app; see `AppModel.handleDeepLink`.
enum CardShareLink {
    static let host = "thetinapp.com"

    static func url(card: CardRecord, setName: String?) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/c/\(card.id)"
        var items = [URLQueryItem(name: "n", value: card.name)]
        if let setName { items.append(URLQueryItem(name: "set", value: setName)) }
        if let img = card.imageURL(quality: "high")?.absoluteString {
            items.append(URLQueryItem(name: "img", value: img))
        }
        c.queryItems = items
        // Components are all app-constructed from known-safe pieces; a nil url here is a
        // programming error, not user input.
        return c.url!
    }
}
