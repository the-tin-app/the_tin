import CoreImage
import Foundation
import Observation

/// Owns the lens session: the photos taken, what was found in each, and the derived rows.
///
/// Ephemeral by design — nothing here is written to disk, and nothing here writes to the
/// collection. A lens session lasts as long as the screen does.
@MainActor @Observable
final class LensModel {
    var photos: [UUID: [LensCell]] = [:]
    var images: [UUID: CIImage] = [:]
    var filter = LensFilter()
    private(set) var isWorking = false

    /// Prices and names for identified cards, filled in from ONE batched catalog read as pass B
    /// resolves them. The row view reads these — it never queries the catalog itself.
    var priceCache: [String: Double] = [:]
    var nameCache: [String: String] = [:]
    var ownedIds: Set<String> = []

    private let source: LensPhotoSource?
    private let catalog: CatalogStore?
    private let matcher: Matcher?
    private let wanted: Set<String>
    /// Built on the first shutter press, not in `init`: `LiveLensWork` has to capture a closure
    /// that reads `images` off this very model, which does not exist yet at init time.
    private var queue: LensQueue?

    init(source: LensPhotoSource? = nil, catalog: CatalogStore? = nil, matcher: Matcher? = nil,
         wanted: Set<String> = [], owned: Set<String> = []) {
        self.source = source
        self.catalog = catalog
        self.matcher = matcher
        self.wanted = wanted
        self.ownedIds = owned
    }

    /// Pure-state instance for unit tests — no camera, no matcher, no catalog.
    static func forTesting() -> LensModel { LensModel() }

    var rows: [LensRow] {
        LensResults.apply(filter, to: LensResults.rows(photos: photos, prices: priceCache,
                                                       owned: ownedIds, names: nameCache))
    }

    /// The headline number: how many cards in front of you are on your wishlist.
    var wishlistHitCount: Int {
        photos.values.flatMap { $0 }.filter(\.onWishlist).count
    }

    /// Stated to the user, never swallowed.
    var unreadableCount: Int { unreadableReasons.count }

    /// The distinct reasons, verbatim, so the footer can name them ("reflection, blur") instead
    /// of just admitting a number.
    var unreadableReasons: [String] {
        photos.values.flatMap { $0 }.compactMap {
            if case .unreadable(let why) = $0.state { return why }
            return nil
        }
    }

    /// Cards the lens saw and read but could not name. Also stated: an outline on the photo with
    /// no row is a failure the user can see, and silence about it is what makes the hits look
    /// untrustworthy.
    var unidentifiedCount: Int {
        photos.values.flatMap { $0 }.filter { $0.state == .noMatch }.count
    }

    func shoot() async {
        guard let source, let queue = ensureQueue() else { return }
        // nil means "not ready" (session still starting, or a capture already in flight), NOT
        // "failed" — see `LensPhotoSource.capture`. Nothing is shown to the user for it.
        guard let shot = await source.capture() else { return }
        images[shot.id] = shot.image
        photos[shot.id] = []
        await queue.enqueue(photoId: shot.id)
        // A drain already running will pick this photo up on its next iteration, and the queue's
        // whole priority rule is that it re-checks pass A first — so a second shutter press must
        // NOT start a second drain racing the first over the same two lists.
        guard !isWorking else { return }
        isWorking = true
        await queue.drain()
        isWorking = false
    }

    func reset() {
        photos.removeAll()
        images.removeAll()
        priceCache.removeAll()
        nameCache.removeAll()
        filter = LensFilter()
    }

    private func ensureQueue() -> LensQueue? {
        if let queue { return queue }
        guard let matcher else { return nil }
        let work = LiveLensWork(matcher: matcher,
                                imageForPhoto: { [weak self] id in await self?.images[id] },
                                wanted: wanted)
        let q = LensQueue(work: work) { [weak self] id, cells in
            await self?.apply(id, cells: cells)
        }
        queue = q
        return q
    }

    private func apply(_ photoId: UUID, cells: [LensCell]) async {
        photos[photoId] = cells
        // Detect and pass A produce no card ids at all, so this is a no-op until pass B lands.
        await resolveMetadata(for: cells.compactMap(\.cardId))
    }

    /// One batched read per newly-identified set of cards, off the MainActor. Keyed on the name
    /// cache: a card the catalog has no price for would otherwise be re-read forever.
    private func resolveMetadata(for ids: [String]) async {
        guard let catalog else { return }
        let missing = Array(Set(ids.filter { nameCache[$0] == nil }))
        guard !missing.isEmpty else { return }
        let out = await Task.detached(priority: .userInitiated) {
            LensModel.read(missing, from: catalog)
        }.value
        nameCache.merge(out.names) { _, new in new }
        priceCache.merge(out.prices) { _, new in new }
    }

    nonisolated private static func read(_ ids: [String], from catalog: CatalogStore)
        -> (names: [String: String], prices: [String: Double]) {
        let cards = (try? catalog.cards(ids: ids)) ?? []
        // `previewPrices` rather than `prices`: it already returns the best *ungraded* market
        // price per card as a plain Double, and excludes graded prices on purpose — a slab price
        // would badly misrepresent a raw card sitting in a case.
        let prices = (try? catalog.previewPrices(cardIds: ids)) ?? [:]
        return (Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.name) }), prices)
    }
}
