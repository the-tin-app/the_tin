import Foundation

/// Warms the durable `ImageCache` with card art ahead of a swipe so `CardImageView` renders
/// instantly instead of popping in once the card is centred. Fire-and-forget; each URL is
/// fetched at most once per session (deduped here), and `ImageCache` persists it so swiping
/// back and forth never re-hits the network.
@MainActor
final class CardImagePrefetcher {
    private var requested: Set<URL> = []
    private let fetch: (URL) -> Void

    /// `fetch` is injectable for tests; the default warms `ImageCache.shared` off the main thread.
    init(fetch: @escaping (URL) -> Void = { url in
        Task.detached(priority: .utility) { _ = await ImageCache.shared.image(for: url) }
    }) {
        self.fetch = fetch
    }

    /// Kick off a cache-warming fetch for each not-yet-requested URL, in first-seen order.
    func prefetch(_ urls: [URL]) {
        for url in urls where requested.insert(url).inserted { fetch(url) }
    }
}
