import CoreImage
import Foundation
import Observation

/// Owns a virtual-binder session: what shape the binder is, which photograph is being asked for,
/// what was found in each, and the card in every pocket.
///
/// **Read-only.** Nothing here writes to the collection. Staging, condition and committing are
/// phase 2 and deliberately absent — phase 1 is what tells us how capture and browsing feel in a
/// real shop, and it needs none of that.
@MainActor @Observable
final class BinderModel {

    enum Phase: Equatable {
        /// How many pockets across and down. One question, then the camera.
        case setup
        /// Working through this page's tiles.
        case capturing
        /// Flipping through the finished binder.
        case browsing
    }

    private(set) var phase: Phase
    private(set) var scan: BinderScan
    /// Which tile of the current page is being asked for. `tiles.count` means the page is done.
    private(set) var tileIndex = 0
    private(set) var page = 0
    private(set) var isWorking = false

    var filter = BinderFilter()

    /// Prices, names and set names for resolved cards, filled from ONE batched catalog read as pass B
    /// resolves them. Row and grid views read these — they never query the catalog themselves.
    private(set) var priceCache: [String: Double] = [:]
    /// Whole records, not just names: `CardImageView` needs `imageBase`/`tcgplayerId` to build an art
    /// URL, and a pocket in a grid must never read the catalog from its own `body`.
    private(set) var cardCache: [String: CardRecord] = [:]
    private(set) var setNameCache: [String: String] = [:]
    var ownedIds: Set<String> = []

    /// Source photographs, held for the life of the session so pass B can rebuild plates and the
    /// verification crop can be cut. Dropped by `finish()` — the tile JPEGs on disk take over.
    private(set) var images: [UUID: CIImage] = [:]
    private var tileByPhoto: [UUID: BinderTile] = [:]
    private var cellsByPhoto: [UUID: [LensCell]] = [:]

    private let source: LensPhotoSource?
    private let catalog: CatalogStore?
    private let matcher: Matcher?
    private let index: CandidateNarrowing?
    private let wanted: Set<String>
    private let cache: BinderCache
    private var queue: LensQueue?
    /// Bumped by `reset()`. Every queue's update closure captures the token it was built under, so
    /// work still in flight from a cleared session lands nowhere.
    private var session = UUID()

    init(source: LensPhotoSource? = nil, catalog: CatalogStore? = nil, matcher: Matcher? = nil,
         index: CandidateNarrowing? = nil, wanted: Set<String> = [], owned: Set<String> = [],
         cache: BinderCache = .shared, now: Date = Date()) {
        self.source = source
        self.catalog = catalog
        self.matcher = matcher
        self.index = index
        self.wanted = wanted
        self.ownedIds = owned
        self.cache = cache
        // A scan survives the screen — that is the whole reason it is cached — so a session opens
        // on yesterday's binder if there is one, and on the setup question if there isn't.
        if let saved = cache.load(now: now) {
            scan = saved
            phase = .browsing
            page = 0
        } else {
            scan = BinderScan(shape: AppConfig.binderShape, createdAt: now)
            phase = .setup
        }
    }

    /// Pure-state instance for unit tests — no camera, no matcher, no catalog, no shared cache.
    static func forTesting(shape: BinderShape = .default, cache: BinderCache) -> BinderModel {
        let m = BinderModel(cache: cache)
        m.begin(shape: shape)
        return m
    }

    // MARK: - Shape and progress

    var shape: BinderShape { scan.shape }
    var tiles: [BinderTile] { BinderPlan.tiles(shape: shape, page: page) }
    var currentTile: BinderTile? { tileIndex < tiles.count ? tiles[tileIndex] : nil }
    var isPageComplete: Bool { tileIndex >= tiles.count }

    /// "Photo 2 of 4 · page 1" — where you are in the whole job, which is the only thing that makes
    /// nine shots for a 5×5 page feel finite.
    var progressText: String {
        let n = min(tileIndex + 1, tiles.count)
        return "Photo \(n) of \(tiles.count) · page \(page + 1)"
    }

    var currentTileName: String {
        currentTile.map { BinderPlan.name($0, shape: shape) } ?? "the whole page"
    }

    /// Leaves setup for the camera. Remembers the shape: which binder you own is a property of you,
    /// not of this session.
    func begin(shape: BinderShape) {
        AppConfig.binderShape = shape
        scan.shape = shape
        phase = .capturing
        page = 0
        tileIndex = 0
    }

    // MARK: - Capture

    func shoot() async {
        guard let source, let tile = currentTile, let queue = ensureQueue() else { return }
        // nil means "not ready" (session still starting, or a capture already in flight), NOT
        // "failed" — see `LensPhotoSource.capture`. Nothing is shown to the user for it.
        guard let shot = await source.capture() else { return }
        accept(shot.image, for: tile)
        isWorking = true
        await queue.enqueue(photoId: shot.id)
        // Always safe to call: `drain()` is idempotent on the actor, so a second shutter press
        // returns straight away and lets the running loop pick the new photo up.
        await queue.drain()
        isWorking = await queue.isDraining
    }

    /// Records a photograph against a tile and advances. Split out from `shoot()` so the whole
    /// capture-to-slot path is testable without a camera.
    func accept(_ image: CIImage, for tile: BinderTile, photoId: UUID = UUID()) {
        // A re-shot tile's previous machine answers go, so a card that has since been pulled from a
        // pocket doesn't linger. Hand-picked answers stay: the user's correction outlives a re-shoot.
        scan.entries.removeAll { $0.tile == tile.id && !$0.byHand }
        // Counted HERE, on the photograph, not on `nextPage`/`finish`. Those only fire when the user
        // navigates tidily, and "shoot half of page 3, then tap Finish" is not tidy — it left
        // `pagesCaptured` one short and made every card on that page unreachable in the grid.
        scan.pagesCaptured = max(scan.pagesCaptured, tile.page + 1)
        images[photoId] = image
        tileByPhoto[photoId] = tile
        cellsByPhoto[photoId] = []
        writeTileImage(image, tile: tile)
        if tile == currentTile { tileIndex += 1 }
        persist()
    }

    /// Back one photograph, to re-frame a shot the user didn't like. Only ever within the page being
    /// captured — a finished page is re-entered through the grid, not by walking backwards.
    func retakePrevious() {
        guard tileIndex > 0 else { return }
        tileIndex -= 1
    }

    /// Page done. Either move on to the next page of the same binder, or stop and browse.
    func nextPage() {
        page += 1
        tileIndex = 0
        phase = .capturing
        persist()
    }

    func finish() {
        page = 0
        phase = .browsing
        // The source photographs are the biggest thing in memory by an order of magnitude — a 24.5 MP
        // CIImage each. Browsing needs the tile JPEGs on disk, not these, and jetsam is uncatchable
        // by Crashlytics.
        images.removeAll()
        tileByPhoto.removeAll()
        cellsByPhoto.removeAll()
        persist()
    }

    func reset() {
        session = UUID()
        cancel()
        queue = nil
        images.removeAll()
        tileByPhoto.removeAll()
        cellsByPhoto.removeAll()
        priceCache.removeAll()
        cardCache.removeAll()
        setNameCache.removeAll()
        filter = BinderFilter()
        cache.clear()
        scan = BinderScan(shape: scan.shape, createdAt: Date())
        page = 0
        tileIndex = 0
        phase = .setup
    }

    /// Pauses the work without losing it — for leaving the screen. ⚠️ Every `cancel()` needs a
    /// `resume()` on the matching lifecycle event, or a pocket sits half-read forever and the screen
    /// says nothing about it.
    func cancel() {
        isWorking = false
        guard let queue else { return }
        Task { await queue.pause() }
    }

    func resume() {
        guard let queue else { return }
        Task {
            guard await queue.hasBacklog else { return }
            isWorking = true
            await queue.drain()
            isWorking = await queue.isDraining
        }
    }

    // MARK: - The binder

    /// ⚠️ Takes the max with the highest page any card actually landed on, so the grid can never hide
    /// a pocket that holds something. A counter alone is one bad navigation away from being wrong, and
    /// the failure is silent: the card is in the scan, in the list, and on no page you can flip to.
    var pageCount: Int {
        max(scan.pagesCaptured, (scan.entries.map(\.slot.page).max() ?? 0) + 1, 1)
    }

    func entry(_ slot: BinderSlot) -> BinderSlotEntry? { scan.entry(slot) }

    func slots(onPage page: Int) -> [BinderSlot] {
        (0..<shape.rows).flatMap { r in
            (0..<shape.cols).map { BinderSlot(page: page, row: r, col: $0) }
        }
    }

    var rows: [BinderRow] {
        BinderResults.apply(filter, to: BinderResults.rows(scan, prices: priceCache,
                                                           cards: cardCache, sets: setNameCache,
                                                           owned: ownedIds))
    }

    /// Distinct set names present in the scan, for the set filter. Sorted, and only what is actually
    /// there — offering all 180 sets when the binder holds three is a menu, not a filter.
    var setNames: [String] {
        Array(Set(scan.entries.compactMap { $0.cardId.flatMap { setNameCache[$0] } })).sorted()
    }

    func name(_ cardId: String) -> String { cardCache[cardId]?.name ?? cardId }

    var wishlistHitCount: Int { scan.entries.filter(\.onWishlist).count }
    var resolvedCount: Int { scan.entries.filter(\.isResolved).count }
    var unresolvedCount: Int { scan.entries.filter { !$0.isResolved }.count }

    /// The user's answer, from the chooser or from manual search. Wins over anything the matcher
    /// says, now or later.
    func pick(_ cardId: String, for slot: BinderSlot) {
        var e = scan.entry(slot) ?? BinderSlotEntry(slot: slot)
        e.cardId = cardId
        e.options = []
        e.byHand = true
        e.onWishlist = wanted.contains(cardId)
        scan.put(e)
        persist()
        Task { await resolveMetadata(for: [cardId]) }
    }

    /// Puts a pocket back to "nothing here" — for a pocket the app filled with a card that isn't in
    /// it and the user can't find the right one.
    func clearSlot(_ slot: BinderSlot) {
        scan.entries.removeAll { $0.slot == slot }
        persist()
    }

    // MARK: - Internals

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
        guard session == self.session, let tile = tileByPhoto[photoId],
              let extent = images[photoId]?.extent else { return }
        cellsByPhoto[photoId] = cells
        assignSlots(cells: cells, tile: tile, extent: extent)
        await resolveMetadata(for: cells.compactMap(\.cardId))
    }

    /// One photograph's detections → pockets. Quantize every detection onto the tile's 2×2 sub-grid,
    /// then let the best observation take each pocket; `BinderPlan.assign` is where the phantom filter
    /// and the overlap vote live.
    ///
    /// Internal rather than private so a test can drive the whole capture-to-pocket path with hand-made
    /// cells — no camera, no Vision, no fingerprint pack.
    func assignSlots(cells: [LensCell], tile: BinderTile, extent: CGRect) {
        let observations = cells.map { cell -> (slot: BinderSlot, score: Int, fpCount: Int,
                                               value: (LensCell, CGRect)) in
            let rect = cell.quad.normalizedRect(in: extent)
            return (BinderPlan.slot(centre: CGPoint(x: rect.midX, y: rect.midY), in: tile),
                    cell.inliers, cell.fpCount, (cell, rect))
        }
        for (slot, found) in BinderPlan.assign(observations, shape: shape) {
            let (cell, rect) = found
            scan.put(BinderSlotEntry(slot: slot, cardId: cell.cardId, options: cell.chooserOptions,
                                     inliers: cell.inliers, onWishlist: cell.onWishlist,
                                     tile: tile.id, crop: rect))
        }
        persist()
    }

    private func persist() { cache.save(scan) }

    /// One batched read per newly-resolved set of cards, off the MainActor. Keyed on the card cache:
    /// a card the catalog has no price for would otherwise be re-read forever.
    private func resolveMetadata(for ids: [String]) async {
        guard let catalog else { return }
        let missing = Array(Set(ids.filter { cardCache[$0] == nil }))
        guard !missing.isEmpty else { return }
        let out = await Task.detached(priority: .userInitiated) {
            BinderModel.read(missing, from: catalog)
        }.value
        cardCache.merge(out.cards) { _, new in new }
        setNameCache.merge(out.sets) { _, new in new }
        priceCache.merge(out.prices) { _, new in new }
    }

    nonisolated private static func read(_ ids: [String], from catalog: CatalogStore)
        -> (cards: [String: CardRecord], sets: [String: String], prices: [String: Double]) {
        let cards = (try? catalog.cards(ids: ids)) ?? []
        let setNames = Dictionary(
            uniqueKeysWithValues: ((try? catalog.sets()) ?? []).map { ($0.id, $0.name) })
        // `previewPrices` rather than `prices`: it already returns the best *ungraded* market price
        // per card as a plain Double, and excludes graded prices on purpose — a slab price would
        // badly misrepresent a raw card sitting in a binder.
        let prices = (try? catalog.previewPrices(cardIds: ids)) ?? [:]
        return (Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: cards.compactMap { c in
                    setNames[c.setId].map { (c.id, $0) }
                }),
                prices)
    }

    /// A downscaled JPEG of the whole tile, written once per shot.
    ///
    /// ⚠️ This is the verification surface, and it is not optional polish. A grid of synthetic
    /// catalog art makes a wrong identification **invisible** — nothing on screen disagrees with a
    /// confident wrong answer. A few hundred KB on a cache that expires in a day buys the user a
    /// reason to believe the grid, and gives a correction an evidence base instead of a guess.
    private func writeTileImage(_ image: CIImage, tile: BinderTile) {
        let cache = self.cache
        let id = tile.id
        Task.detached(priority: .utility) {
            let ext = image.extent
            guard ext.width > 0, ext.height > 0 else { return }
            let s = min(1, 1_400 / max(ext.width, ext.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let data = try? CIContext().jpegRepresentation(
                of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
            else { return }
            cache.writeTile(id, jpeg: data)
        }
    }
}

extension LensCell {
    /// Inlier count of a settled answer, and **0 for anything else, including `.ambiguous`**. That is
    /// the ranking `BinderPlan.assign` uses to decide which of two looks at the same pocket wins, and
    /// scoring `.ambiguous` at 0 is what makes a resolved look from an overlapping tile beat an
    /// unresolved one — which is the entire value of photographing a row twice.
    var inliers: Int {
        if case .identified(_, let n) = state { return n }
        return 0
    }
}
