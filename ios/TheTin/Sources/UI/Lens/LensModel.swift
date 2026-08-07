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
    /// The OCR gate's narrowing index — the same one the live scanner uses, built once per pack.
    private let index: CandidateNarrowing?
    private let wanted: Set<String>
    /// Built on the first shutter press, not in `init`: `LiveLensWork` has to capture a closure
    /// that reads `images` off this very model, which does not exist yet at init time.
    private var queue: LensQueue?
    /// Bumped by `reset()`. Every queue's update closure captures the token it was built under,
    /// so work still in flight from a cleared session lands nowhere.
    private var session = UUID()

    init(source: LensPhotoSource? = nil, catalog: CatalogStore? = nil, matcher: Matcher? = nil,
         index: CandidateNarrowing? = nil, wanted: Set<String> = [], owned: Set<String> = []) {
        self.source = source
        self.catalog = catalog
        self.matcher = matcher
        self.index = index
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
    /// ⚠️ `cardId == nil` too, not just `.noMatch`: a wishlist hit that pass B then failed to
    /// place in the open set still has a row, a name and a price from pass A. Counting it here as
    /// well would print "1 card wasn't recognized" directly above the card it named.
    var unidentifiedCount: Int {
        photos.values.flatMap { $0 }.filter { $0.state == .noMatch && $0.cardId == nil }.count
    }

    func shoot() async {
        guard let source, let queue = ensureQueue() else { return }
        // nil means "not ready" (session still starting, or a capture already in flight), NOT
        // "failed" — see `LensPhotoSource.capture`. Nothing is shown to the user for it.
        guard let shot = await source.capture() else { return }
        images[shot.id] = shot.image
        photos[shot.id] = []
        isWorking = true
        await queue.enqueue(photoId: shot.id)
        // Always safe to call: `drain()` is idempotent on the actor, so a second shutter press
        // returns straight away and lets the running loop pick the new photo up (its priority
        // rule re-checks pass A every iteration). The guard is deliberately NOT here — a
        // MainActor flag cannot be consistent with `awaitingA`, and getting it wrong strands the
        // photo with no drainer and no spinner.
        await queue.drain()
        isWorking = await queue.isDraining
    }

    /// Pauses the work without losing it — for leaving the screen, where nothing should be burning
    /// both cores behind a view that is gone, but the reading must carry on where it stopped when
    /// the user comes back. ⚠️ Every `cancel()` needs a `resume()` on the matching lifecycle event,
    /// or a photo sits half-read forever and the screen says nothing about it.
    func cancel() {
        isWorking = false
        guard let queue else { return }
        Task { await queue.pause() }
    }

    /// Restarts a paused drain. No-op when there is nothing waiting, so re-entering a finished
    /// session doesn't flash "Reading…".
    func resume() {
        guard let queue else { return }
        Task {
            guard await queue.hasBacklog else { return }
            isWorking = true
            await queue.drain()
            isWorking = await queue.isDraining
        }
    }

    /// Clears the session. Any drain still running belongs to the OLD session: it is paused and
    /// then the queue is DROPPED, which discards the backlog and the cached fingerprints along
    /// with it — that is what Clear means, and it is the one place a discard is right. The next
    /// shutter press builds a fresh queue, and the
    /// stale drain's updates are discarded by the session check in `apply`. Without that, a Clear
    /// tapped during "Reading…" lets a late `onUpdate` put a photo back into `photos` — which then
    /// looks like a live session to `ScanTabContainer` and stops it refreshing the wishlist
    /// snapshot on re-entry.
    func reset() {
        session = UUID()
        cancel()
        queue = nil
        photos.removeAll()
        images.removeAll()
        priceCache.removeAll()
        nameCache.removeAll()
        filter = LensFilter()
    }

    private func ensureQueue() -> LensQueue? {
        if let queue { return queue }
        guard let matcher, let index else { return nil }
        let work = LiveLensWork(matcher: matcher, index: index,
                                imageForPhoto: { [weak self] id in await self?.images[id] },
                                wanted: wanted)
        let token = session
        let q = LensQueue(work: work) { [weak self] id, cells in
            await self?.apply(id, cells: cells, session: token)
        }
        queue = q
        return q
    }

    private func apply(_ photoId: UUID, cells: [LensCell], session: UUID) async {
        guard session == self.session else { return }   // a cleared session's late update
        photos[photoId] = cells
        // Pass A's hits carry a card id too, so their names and prices are resolved here — the
        // whole pass-A phase would otherwise show rows with no name and no price.
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
