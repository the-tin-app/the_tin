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

    /// Source photographs, held only until pass B has finished with each one — see `apply`. A 48 MP
    /// CIImage is an order of magnitude bigger than anything else on this screen, and holding a whole
    /// session's worth at once is the jetsam class this app has already been killed by.
    private(set) var images: [UUID: CIImage] = [:]
    private var tileByPhoto: [UUID: BinderTile] = [:]
    /// The photograph's extent, kept SEPARATELY from the photograph. `apply` needs it to normalize quad
    /// centres, and it must survive the image being evicted — reading `images[id]?.extent` made the
    /// eviction and the assignment fight over the same dictionary.
    private var extentByPhoto: [UUID: CGRect] = [:]

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
        guard let image = await source.capture() else { return }
        // ⚠️ The queue is handed the id `accept` MINTED, and that is the whole point of it returning
        // one. This used to be two independent ids — `accept` defaulted `photoId` to a fresh UUID
        // while the queue was enqueued with the capture's own id — so `detect` looked up the image
        // under an id nothing had stored it against, got nil, and returned zero cells. Four pages
        // photographed, every pocket empty, no error anywhere. There is now one id and one source
        // for it, because two that merely agree is a bug waiting for a refactor.
        isWorking = true
        await queue.enqueue(photoId: accept(image, for: tile))
        // Always safe to call: `drain()` is idempotent on the actor, so a second shutter press
        // returns straight away and lets the running loop pick the new photo up.
        await queue.drain()
        isWorking = await queue.isDraining
    }

    /// Records a photograph against a tile, advances, and returns the id the photograph is stored
    /// under — which is what the queue must be given. Split out from `shoot()` so the whole
    /// capture-to-pocket path is testable without a camera.
    @discardableResult
    func accept(_ image: CIImage, for tile: BinderTile) -> UUID {
        let photoId = UUID()
        // A re-shot tile's previous machine answers go, so a card that has since been pulled from a
        // pocket doesn't linger. Hand-picked answers stay: the user's correction outlives a re-shoot.
        scan.entries.removeAll { $0.tile == tile.id && !$0.byHand }
        // Counted HERE, on the photograph, not on `nextPage`/`finish`. Those only fire when the user
        // navigates tidily, and "shoot half of page 3, then tap Finish" is not tidy — it left
        // `pagesCaptured` one short and made every card on that page unreachable in the grid.
        scan.pagesCaptured = max(scan.pagesCaptured, tile.page + 1)
        images[photoId] = image
        tileByPhoto[photoId] = tile
        extentByPhoto[photoId] = image.extent
        persistImages(image, tile: tile)
        if tile == currentTile { tileIndex += 1 }
        shotsTaken += 1
        persist()
        return photoId
    }

    /// How many photographs this session has taken. Drives the shutter flash and the haptic — a
    /// capture where only a caption changes doesn't read as a capture at all.
    private(set) var shotsTaken = 0

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

    /// Stop shooting and go and look at the binder.
    ///
    /// ⚠️ Deliberately clears NOTHING. It used to drop `images` and `tileByPhoto` on the reasoning that
    /// browsing has no use for a 48 MP photograph — which is true, and which silently destroyed every
    /// answer still in flight. Pass B is the slow stage; tapping Done straight after the last shutter
    /// press is the normal thing to do, and it left `apply` unable to find the tile for the photographs
    /// still being read, so their pockets kept whatever `detect` had put there: a page of unreadable
    /// pockets on a page of perfectly readable cards.
    ///
    /// Memory is handled where it belongs instead — per photograph, in `apply`, the moment pass B has
    /// finished with it.
    func finish() {
        page = 0
        phase = .browsing
        persist()
    }

    func reset() {
        session = UUID()
        cancel()
        queue = nil
        images.removeAll()
        tileByPhoto.removeAll()
        extentByPhoto.removeAll()
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

    /// Fills art, names, set names and prices for whatever the scan already holds.
    ///
    /// ⚠️ Not belt-and-braces. Metadata is otherwise resolved only as pass B finds cards, so a scan
    /// that came **off disk** has entries and nothing else — and the grid renders as a page of grey
    /// rectangles with no names and no prices. The feature looks broken at exactly the moment the
    /// cache did its job. Cheap and idempotent: `resolveMetadata` skips anything already cached.
    func hydrate() async {
        await resolveMetadata(for: scan.entries.compactMap(\.cardId))
    }

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

    /// Where a tile's photograph lives. Routed through the model so the view reads the cache the model
    /// was BUILT with — `BinderCache.shared` hardcoded in a view is right today and silently wrong the
    /// first time anything injects a different one.
    func tileURL(_ tileId: String) -> URL { cache.tileURL(tileId) }

    var wishlistHitCount: Int { scan.entries.filter(\.onWishlist).count }
    var resolvedCount: Int { scan.entries.filter(\.isResolved).count }
    /// Pockets holding a card the app couldn't name but CAN offer a choice for.
    var unresolvedCount: Int {
        scan.entries.filter { !$0.isResolved && !$0.options.isEmpty }.count
    }
    /// Pockets holding a card that couldn't be read at all — stated separately, because "pick one of
    /// these four" and "we couldn't see it" are different answers and lumping them promises a chooser
    /// that measurably isn't worth offering (the four best guesses held the truth 1 time in 12).
    var unreadCount: Int {
        scan.entries.filter { !$0.isResolved && $0.options.isEmpty }.count
    }

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
              let extent = extentByPhoto[photoId] else { return }
        assignSlots(cells: cells, tile: tile, extent: extent)

        // ⚠️ Drop the photograph the moment nothing needs it again. `finish()` used to be the only thing
        // that cleared `images`, so a four-page 3×3 scan held SIXTEEN full-resolution photographs at
        // once — and at 48 MP that is exactly the jetsam class this app has already been killed by, with
        // SIGKILL guaranteeing Crashlytics never sees it. Nothing after pass B reads the source: the
        // verification crop comes off the downscaled tile JPEG on disk.
        //
        // `.pending` is the test because it is precisely "pass B has not run for this cell yet" — pass A
        // leaves it pending, and `.unreadable` cells never enter it. A photograph with no cells at all
        // is trivially done and there is nothing to process.
        if cells.allSatisfy({ $0.state != .pending }) {
            images[photoId] = nil
            tileByPhoto[photoId] = nil
            extentByPhoto[photoId] = nil
        }
        await resolveMetadata(for: cells.compactMap(\.cardId))
    }

    /// One photograph's detections → pockets. Quantize every detection onto the tile's 2×2 sub-grid,
    /// then let the best observation take each pocket; `BinderPlan.assign` is where the phantom filter
    /// and the overlap vote live.
    ///
    /// Internal rather than private so a test can drive the whole capture-to-pocket path with hand-made
    /// cells — no camera, no Vision, no fingerprint pack.
    func assignSlots(cells: [LensCell], tile: BinderTile, extent: CGRect) {
        // ⚠️ Phantoms are excluded BEFORE the sub-grid is worked out, not after. `BinderPlan.slots`
        // decides where the dividing line falls from the spread of what it is given, so one glare band
        // at the edge of the frame would drag that line and mis-row every real card with it.
        //
        // ⚠️ And `.unreadable` cells are KEPT, which `fpCount` alone cannot express — a card lost to
        // glare or too blurred to fingerprint has no keypoints at all, so a keypoint floor drops it and
        // the pocket renders as EMPTY. "There is nothing in this pocket" and "there is a card here I
        // could not read" are different answers, and quietly giving the first one is the silent miss this
        // whole feature exists to avoid.
        let rects = cells.map { $0.quad.normalizedRect(in: extent) }
        let short = min(extent.width, extent.height)
        let keep = zip(cells, rects).filter { cell, rect in
            if cell.fpCount >= BinderPlan.minFpCount { return true }
            guard cell.isUnreadable else { return false }
            // No fingerprint to judge by, so judge by size — and because capture is ALWAYS 2×2, a card
            // occupies about half the frame whatever the binder's shape, which makes a fraction of the
            // frame a principled test rather than a fitted one. Measured over 179 real cells: every
            // card-sized quad was ≥ 0.27 of the frame's short side and every phantom ≤ 0.262, and
            // nothing above 0.20 failed to fingerprint at all.
            return min(rect.width * extent.width, rect.height * extent.height)
                >= short * BinderPlan.minCardShortSideFraction
        }
        let real = keep.map(\.0), keptRects = keep.map(\.1)
        let slots = BinderPlan.slots(rects: keptRects, in: tile)
        let observations = zip(zip(real, keptRects), slots).map { pair, slot in
            (slot: slot, score: pair.0.inliers, fpCount: pair.0.fpCount, value: (pair.0, pair.1))
        }
        BinderDiag.record(cells: real, rects: keptRects, slots: slots, tile: tile)
        for (slot, found) in BinderPlan.assign(observations, shape: shape) {
            let (cell, rect) = found
            scan.put(BinderSlotEntry(slot: slot, cardId: cell.cardId, options: cell.chooserOptions,
                                     inliers: cell.inliers, onWishlist: cell.onWishlist,
                                     tile: tile.id, crop: rect, unreadable: cell.unreadableReason))
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
    private func persistImages(_ image: CIImage, tile: BinderTile) {
        let cache = self.cache
        let id = tile.id
        // ⚠️ ONE task doing both writes, sequentially. Two concurrent JPEG encodes of a 48 MP image
        // each materialise their own full-size intermediate, and the DEBUG build — the one being
        // tested on a device — does exactly two per shutter press. Sequential halves the peak, and
        // jetsam samples the peak.
        Task.detached(priority: .utility) {
            let context = CIContext()
            let ext = image.extent
            guard ext.width > 0, ext.height > 0 else { return }
            let s = min(1, 1_400 / max(ext.width, ext.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            if let data = try? context.jpegRepresentation(
                of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) {
                cache.writeTile(id, jpeg: data)
            }
            BinderDiag.write(photo: image, tile: id, context: context)
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
