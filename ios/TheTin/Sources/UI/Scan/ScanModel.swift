import Observation
import CoreImage
import CoreVideo
import Foundation
import os

/// Outcome of processing a single frame through the off-main `ScanPipeline`.
/// `poolCount` is how many catalog cards the OCR narrowed to for this frame — surfaced only so
/// the viewfinder can say what it's doing ("Checking 40 cards…") instead of sitting silent while
/// a slow device grinds. Zero means the text gate produced nothing usable yet.
struct FrameOutcome {
    let coverage: Double
    let noCard: Bool
    let event: ScanEvent?
    var poolCount: Int = 0
    /// `ScanSession`'s lock-streak progress, for the viewfinder's ring and counter.
    var confirmations: Int = 0
    var confirmationsNeeded: Int = 0
}

/// Decides when the camera may drop to its idle frame rate. Pure policy, no camera and no CV,
/// so the rule that governs the scanner's power draw is checkable without either.
///
/// The scanner is left open and face-up on a table between stacks of cards. At the capture
/// session's default rate that idle time costs a document-segmentation pass ~22 times a second
/// against a tabletop, plus the ISP behind it, indefinitely — which is what makes the phone hot
/// during a long look-up session.
struct CameraThrottle {
    /// Consecutive empty frames before idling. Comfortably above `LockConfig.graceMisses` (12),
    /// which is the run of dropouts a card being held by hand is already expected to produce —
    /// idle below that and a mid-scan flicker would throttle the camera during a real scan.
    static let emptyFramesBeforeIdle = 30
    private var empty = 0
    private(set) var isIdle = false

    /// Returns the frame rate the camera should now be at, as `isIdle`.
    mutating func update(cardVisible: Bool, modal: Bool) -> Bool {
        // A modal sheet idles immediately AND holds the empty count at zero, so dismissing it
        // returns to the scanning rate on the very next frame instead of after a fresh streak.
        empty = (cardVisible || modal) ? 0 : empty + 1
        isIdle = modal || empty >= Self.emptyFramesBeforeIdle
        return isIdle
    }
}

/// Owns the stateful/heavy per-frame CV cascade (detect → quality-gate → fingerprint →
/// OCR gate → match → session) off the main actor so live 30fps camera capture doesn't
/// jank the UI. `ScanModel` only reads the `FrameOutcome` back on main.
actor ScanPipeline {
    private static let log = Logger(subsystem: "ai.reyes.thetin", category: "scan")
    private let detector: CardDetector
    private let textGate: TextGate
    private let matcher: Matcher
    private let narrowing: CandidateNarrowing
    private let fingerThrottle: Int
    private let minFocus: Double
    private let maxGlare: Double
    private let fingerprint: @Sendable (Data, Int, Int, Int) -> CardFingerprint?
    private let session = ScanSession()
    private var frameIndex = 0
    private var heavyFrames = 0
    /// Pipeline wall-clock across the frames that produced NO diagnostic line — light presence
    /// frames, failed detections, quality-gated frames. Those paths return before `ScanDiag.dump`,
    /// so they were invisible, and the gap between dumped frames is mostly made of them: the iPad
    /// sat at one dumped frame every 5s with no way to see where the 5s went (2026-07-27).
    private var interMs: Double = 0
    private var interFrames = 0

    /// The text stages, held across the frames of one acquisition.
    ///
    /// A plate under a steady hand produces identical OCR frame after frame — measured on an iPad
    /// 2026-07-27, the same "Dondozo eX / 066 / 182" read three times at ~2,400ms each — while the
    /// only thing `ScanSession`'s stability streak needs to see is the VISUAL match. So the text
    /// stages run once per acquisition and the streak still costs three independent RANSAC
    /// confirmations: the lock gate is unchanged, it just stops paying for the same OCR three times.
    ///
    /// Dropped when the card leaves (any no-card frame), when the session is reset or a chooser is
    /// resolved, and — the binder case — when the cached pool stops explaining what the camera
    /// sees. Over a binder the next pocket slides in with NO no-card gap, so nothing else would
    /// notice the swap. A pool built for the previous card cannot produce a strong match for the
    /// new one (its id simply isn't in the pool), so a best-inlier count under the lock floor drops
    /// the cache and the next frame pays for a fresh read.
    ///
    /// The residual case — the new card IS in the old card's pool and matches strongly — degrades
    /// to a chooser rather than a wrong lock: `consistency` checks the winner's name against the
    /// cached OCR text, which belongs to the previous card, so `nameAgrees` fails and
    /// `ScanSession` surfaces options instead of latching.
    private var cachedFields: OcrFields?
    private var cachedPool: [String]?
    /// Matches `LockConfig.tLock` — below it the pool is not explaining the card in front of us.
    private static let poolReuseFloor = 20

    /// Also forgets which way up the card is: the orientation hint describes the SAME thing the
    /// text cache does — "the card currently in front of the camera" — so the two must expire
    /// together, or a swapped card would be rectified upside down using its predecessor's hint.
    private func invalidateTextCache() {
        cachedFields = nil; cachedPool = nil
        detector.forgetOrientation()
        // The picture describes the same thing the text cache and the orientation hint do — "the
        // card in front of the camera right now" — so it expires with them, or a lock would be
        // staged showing its predecessor.
        lastPlate = nil
    }

    /// The centring editor's picture for the card just locked — the card re-cropped with margin
    /// (`EditorPlate`), as JPEG. Rendered ONLY on the frame that locks, never per frame: it is a
    /// second perspective-correct plus a full-size render, and locks are rare while frames are not.
    private var lastPlate: Data?
    private let editorContext = CIContext()

    /// The picture for the card currently in frame, or nil if it has left. Asked for once per lock.
    func currentPlate() -> Data? { lastPlate }

    init(detector: CardDetector, textGate: TextGate, matcher: Matcher, narrowing: CandidateNarrowing,
         fingerThrottle: Int,
         minFocus: Double = 0, maxGlare: Double = 1,
         fingerprint: @escaping @Sendable (Data, Int, Int, Int) -> CardFingerprint? =
            { ScanFingerprinter.fingerprint(pixels: $0, width: $1, height: $2, bytesPerRow: $3) }) {
        self.detector = detector; self.textGate = textGate; self.matcher = matcher
        self.narrowing = narrowing
        self.fingerThrottle = fingerThrottle
        self.minFocus = minFocus; self.maxGlare = maxGlare
        self.fingerprint = fingerprint
    }

    /// Last computed narrowing size, carried across the light/gated frames that don't compute one.
    private var lastPoolCount = 0

    /// Every outcome reports the session's CURRENT streak, not zeros.
    ///
    /// `ScanModel.run` applies this to the viewfinder on every frame with a card in it — including
    /// the three light presence frames between each heavy one. Defaulting those to zero made the
    /// counter oscillate "1 of 3" → "0 of 3" → "2 of 3" at ~80ms intervals, which on device looked
    /// like the streak racing 1→3 in a quarter second (Tomas, iPad, 2026-07-27). A light frame has
    /// no new information about the streak; it must report the streak unchanged, not report none.
    private func outcome(coverage: Double, noCard: Bool, event: ScanEvent?,
                         poolCount: Int? = nil) -> FrameOutcome {
        FrameOutcome(coverage: coverage, noCard: noCard, event: event,
                     poolCount: poolCount ?? lastPoolCount,
                     confirmations: session.confirmations,
                     confirmationsNeeded: session.confirmationsNeeded)
    }

    func process(_ pb: CVPixelBuffer) -> FrameOutcome {
        frameIndex += 1
        var timer = StageTimer()
        let frameStart = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - frameStart
            interMs += Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            interFrames += 1
        }
        if frameIndex % fingerThrottle != 0 {
            // Light frame: presence only — feeds the session's grace/miss accounting without
            // paying rectification + orientation OCR for a plate we'd throw away.
            if timer.measure("presence", { detector.cardPresent(pixelBuffer: pb) }) {
                return outcome(coverage: 0, noCard: false, event: nil)
            }
            _ = session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
            invalidateTextCache()   // card gone → the next one gets a fresh read
            lastPoolCount = 0
            return outcome(coverage: 0, noCard: true, event: nil)
        }
        guard let frame = timer.measure("detect", { detector.detect(pixelBuffer: pb) }) else {
            _ = session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
            invalidateTextCache()
            lastPoolCount = 0
            return outcome(coverage: 0, noCard: true, event: nil)
        }
        // Single-frame quality gate: only fingerprint a sharp, low-glare frame. No cross-frame
        // fusion — the hand-held quad jitters, so per-pixel fusion across frames tears the plate
        // and destroys ORB structure (Plan 5). Temporal robustness comes from ScanSession voting.
        guard frame.focus >= minFocus, frame.glareCoverage <= maxGlare else {
            // A gated frame must still surface an event: with no event the guidance stays stuck
            // on the initial "Frame the card inside the box" even though a card IS detected —
            // which is exactly how the 2026-07-15 binder failure stayed invisible on device.
            return outcome(coverage: 0, noCard: false, event: .guide(bestGuess: nil))
        }
        guard let query = timer.measure("fingerprint", {
            fingerprint(frame.pixels, frame.width, frame.height, frame.bytesPerRow) }) else {
            return outcome(coverage: 0, noCard: false, event: nil)
        }
        // F1b: full-plate OCR (E1) → ranked narrowing pool (E2) → RANSAC-confirm over the pool
        // → per-candidate OCR/twin consistency → ScanSession's F1 lock gate. Replaces the C1
        // interim `matcher.allCardIds` fallback.
        let fields: OcrFields
        let pool: [String]
        if let cachedFields, let cachedPool {
            fields = cachedFields; pool = cachedPool
        } else {
            fields = timer.measure("ocr") { TextGate.extract(plate: frame) }
            pool = timer.measure("pool") { narrowing.pool(fields: fields) }
            cachedFields = fields; cachedPool = pool
        }
        let poolSet = Set(pool)
        let results = timer.measure("match") { (try? matcher.matchRanked(query: query, rankedIds: pool)) ?? [] }
        // The pool no longer explains what we're looking at — a swapped card, or a read that was
        // wrong to begin with. Drop it so the next frame re-reads the text.
        if (results.first?.inliers ?? 0) < Self.poolReuseFloor { invalidateTextCache() }
        let cons = timer.measure("consistency") { Dictionary(results.map { ($0.cardId,
            narrowing.consistency(cardId: $0.cardId, fields: fields, pool: poolSet)) },
            uniquingKeysWith: { a, _ in a }) }
        heavyFrames += 1
        if heavyFrames % 8 == 1 {   // one line every 8 heavy frames — enough to read cadence off Console
            Self.log.info("heavy frame #\(self.heavyFrames) pool=\(pool.count) \(timer.summary)")
        }
        // Frame passed the quality gate → treat as fully "covered" for the lock gate.
        let obs = FrameObservation(
            candidates: results.map { (id: $0.cardId, inliers: $0.inliers) },
            coverage: 1.0, cardPresent: true, gated: !pool.isEmpty, consistency: cons)
        let event = session.ingest(obs)
        // Rendered here, on the locking frame, because this is the only place the source buffer,
        // the quad and the resolved rotation all still exist together — and rendering it AFTER the
        // pool-reuse invalidation above means it survives to be read by `currentPlate()`.
        if case .lock = event, let quad = frame.quad {
            lastPlate = timer.measure("editorPlate") {
                // `unflipped`, NOT `frame.degrees` — recognition keeps the full hint, the picture
                // drops its 0°-vs-180° half. See `EditorPlate.unflipped`.
                EditorPlate.jpeg(pixelBuffer: pb, quad: quad,
                                 degrees: EditorPlate.unflipped(frame.degrees),
                                 context: editorContext)
            }
        }
        #if DEBUG
        ScanDiag.dump(frame: frame, fields: fields, pool: pool, results: results, event: event,
                      stages: "\(timer.summary) [\(detector.lastDetectSummary)]",
                      interMs: interMs, interFrames: interFrames)
        #endif
        interMs = 0; interFrames = 0
        lastPoolCount = pool.count
        return outcome(coverage: 1.0, noCard: false, event: event, poolCount: pool.count)
    }

    // Every path that wipes recognition state also drops the cached read — the user resolving a
    // chooser or hitting Reset is telling us the current interpretation is finished with.
    func acknowledgeChoice(cardId: String) { session.acknowledge(cardId: cardId); invalidateTextCache() }
    func dismissChooser() { session.dismissChooser(); invalidateTextCache() }
    func reset() { session.reset(); invalidateTextCache() }
    func reject(cardId: String) { session.reject(cardId: cardId); invalidateTextCache() }
}

/// One chooser tile: the candidate card plus the set metadata the user actually recognizes
/// (image, name, set, year, number) — never a bare card-id code (Tomas, 2026-07-15).
struct ChooserOption: Identifiable, Equatable {
    let id: String
    let card: CardRecord?
    let setName: String?
    let year: String?
    let setTotal: Int?

    /// "Perfect Order · 2026 · #050/124" — whichever parts resolved.
    var caption: String {
        var parts: [String] = []
        if let setName { parts.append(setName) }
        if let year { parts.append(year) }
        if let number = card?.number {
            parts.append(setTotal.map { "#\(number)/\($0)" } ?? "#\(number)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Drives the live-scan cascade (detect → quality-gate → fingerprint → OCR gate → match →
/// lock) from an injectable `FrameSource` and stages a `ScanDraft` on each lock — a
/// reviewable draft, never an owned `CollectionEntry`. "Continuous staging": the user
/// keeps swapping physical cards under the camera and each confident lock lands in the
/// local staging tray without further taps; routing/commit happens later in review.
@MainActor @Observable
final class ScanModel {
    private let staging: ScanStagingStore
    private let store: CatalogStore
    private let pipeline: ScanPipeline
    /// Written on every frame and read by nothing on screen — kept out of Observation so it
    /// can't register a dependency at camera rate.
    @ObservationIgnored private var throttle = CameraThrottle()

    /// Shown while nothing is detected. The frame rectangle on screen already says this, so
    /// the view suppresses it — named here so the two can't drift apart.
    static let idleGuidance = "Frame the card inside the box"
    var guidance: String = ScanModel.idleGuidance
    var coverage: Double = 0
    var bestGuess: String?

    /// True while frames are actually being examined — drives the viewfinder's activity spinner.
    ///
    /// `coverage` cannot do this job: the pipeline reports a flat 1.0 for any heavy frame and
    /// never resets, so the ring snaps full on the first one and then sits there. Nothing on
    /// screen changed while the scanner worked, and on an iPad — where an A10 does ORB matching a
    /// fraction as fast as a phone — the viewfinder was silent long enough to read as broken.
    /// It wasn't; it was thinking (2026-07-27). A slower system that explains itself beats a fast
    /// one that says nothing until it succeeds.
    private(set) var isExamining = false
    /// How many catalog cards the last examined frame narrowed to. 0 = nothing readable yet.
    private(set) var poolCount = 0

    /// Lock-streak progress from `ScanSession`, and the candidate's NAME rather than its id.
    ///
    /// The viewfinder used to render every confirming frame as the same "Hold steady", so the
    /// three frames the lock gate requires were indistinguishable from a scanner going in circles
    /// — the exact complaint on an iPad 2026-07-27, where the streak takes seconds rather than the
    /// instant it takes on a phone. Naming the card and counting the confirmations makes the wait
    /// legible: you can see it has found something, what it thinks that something is, and how much
    /// longer it needs.
    private(set) var confirmations = 0
    private(set) var confirmationsNeeded = 0
    private(set) var bestGuessName: String?
    /// 0…1 for the viewfinder ring. Replaces `coverage`, which reported a flat 1.0 on every heavy
    /// frame and never reset — the ring snapped full on the first frame and then sat there,
    /// meaning nothing for the rest of the scan.
    var lockProgress: Double {
        guard confirmationsNeeded > 0 else { return 0 }
        return min(1, Double(confirmations) / Double(confirmationsNeeded))
    }

    /// The card just staged, held briefly so the capture is actually announced.
    ///
    /// `stage()` has always set `guidance` to "Added <name> — next card", but `activityText` only
    /// consults `guidance` while a chooser is up, and `bestGuess` stays non-nil after a lock — so
    /// that confirmation fell through to "Hold steady" and was never once displayed.
    private(set) var lastAdded: String?
    private var lastAddedClear: Task<Void, Never>?
    static let addedLinger: Duration = .seconds(2)
    /// Drops `isExamining` once frames stop arriving. In the model, not a view `.task`: the same
    /// reason `undoExpiry` lives here — SwiftUI cancels view tasks whenever it re-identifies the
    /// subtree, and this has to survive that.
    private var examineIdle: Task<Void, Never>?

    /// How long after the last examined frame the spinner keeps turning. Comfortably longer than
    /// the gap between heavy frames on a slow device, or the spinner strobes on the very hardware
    /// it exists to reassure.
    static let examiningLinger: Duration = .seconds(2)

    private func noteExamined(poolCount: Int, confirmations: Int, needed: Int) {
        self.poolCount = poolCount
        self.confirmations = confirmations
        if needed > 0 { self.confirmationsNeeded = needed }
        isExamining = true
        examineIdle?.cancel()
        examineIdle = Task { [weak self] in
            try? await Task.sleep(for: Self.examiningLinger)
            guard !Task.isCancelled else { return }
            self?.isExamining = false
        }
    }

    /// What the viewfinder should say it is doing, in the user's terms.
    var activityText: String {
        if !ambiguous.isEmpty { return guidance }         // the chooser owns the message
        // A capture outranks everything: it is the one moment the user is waiting for, and it was
        // the one message that never appeared.
        if let lastAdded { return "Added \(lastAdded) — next card" }
        if !isExamining { return Self.idleGuidance }
        // Keyed on the STREAK, not on this frame's guess, so the caption and the ring can never
        // disagree — one blurry frame no longer resets the words while the progress holds.
        if confirmations > 0, confirmationsNeeded > 0 {
            let subject = bestGuessName ?? "card"
            return "Confirming \(subject) · \(confirmations) of \(confirmationsNeeded)"
        }
        return poolCount > 0 ? "Checking \(poolCount) cards…" : "Reading the card…"
    }
    var ambiguous: [ChooserOption] = []

    /// What a confident lock does. `false` (default) stages a reviewable draft for the tin;
    /// `true` just identifies the card and stages nothing — the shop question ("what is this,
    /// what's it worth, do I own it?") rather than the cataloguing one. Persisted: which mode you
    /// want follows what you're doing this week, not this launch.
    var isLookUpMode: Bool = AppConfig.scanLookUpMode {
        didSet {
            AppConfig.scanLookUpMode = isLookUpMode
            // Leaving look-up mode must drop any card it had presented. `lookedUpCardId` makes
            // `handle(_:)` discard every event, so carrying one into Add mode means the scanner
            // silently ignores every lock it makes — with no visible cause, because the sheet
            // that would have cleared it belongs to a mode you are no longer in.
            if !isLookUpMode { lookedUpCardId = nil }
        }
    }
    /// Pins the scanner to look-up for callers that have somewhere else to put the card — a trade
    /// reads a stranger's card onto the table, and staging it would file someone else's property
    /// into your tin.
    ///
    /// Deliberately NOT `isLookUpMode = true`: that setter persists, so borrowing the scanner for
    /// one card would silently rewrite the mode the user picked for the Scan tab. This is the
    /// caller's requirement, held for as long as the caller is on screen; `isLookUpMode` stays
    /// the user's preference and is what the mode picker still reads and writes.
    var forcesLookUp = false
    /// The mode the pipeline actually obeys.
    var isLookingUp: Bool { forcesLookUp || isLookUpMode }
    /// The condition new drafts are staged at. Every capture used to be Near Mint with nothing
    /// asked and nothing shown, so a played collection valued itself as mint — and since the
    /// review screen's per-card menu is a per-card tap, nobody was ever going to correct 300 of
    /// them. Set it once for the stack you're holding. Persisted for the same reason as the mode.
    var stagingCondition: CardCondition = AppConfig.scanCondition {
        didSet { AppConfig.scanCondition = stagingCondition }
    }
    /// How the cards being scanned were acquired — set once for a pack rip, applied to every
    /// draft staged after it.
    ///
    /// NOT persisted, unlike the mode and condition beside it. Condition is sticky because NM is
    /// a safe default and being wrong costs a price tier; "Pulled" is a claim about where a card
    /// came from, and left sticky it would quietly label the box you buy next week as pack pulls.
    /// One tap per rip is cheap; a wrong provenance is silent and permanent. It also keeps this
    /// out of `AppConfig`, so no test has to pin it in setUp/tearDown to avoid poisoning the next.
    var stagingVia: AcquiredVia? = nil
    /// Set when a lock resolves in look-up mode. The view presents that card and clears this,
    /// which also resets the scanner so the next card (or the same one again) can be read.
    var lookedUpCardId: String?

    /// Is something actually on screen over the viewfinder? This is what the frame loop throttles
    /// on, and it is NOT the same question as "did we just recognise a card".
    ///
    /// ⚠️ A borrowed viewfinder (`forcesLookUp`) sets `lookedUpCardId` as a **handoff, not a
    /// presentation**: the trade picker takes the card in `onChange` and clears it, and nothing is
    /// ever presented over the camera. Counting that as modal idled the camera to 2fps on every
    /// single card — and since the wake-up frame then arrives at the idle rate, it cost up to half
    /// a second of dead viewfinder per card, in the one flow whose entire point is working through
    /// a pile without pause. The chooser stays modal in both worlds: it really is on screen.
    /// True while the review sheet is up. Owned by the model rather than the view because the
    /// frame loop is what has to know: `isModalPresented` is the whole "should the camera be
    /// working" question, and a `@State` flag in `ScanView` was invisible to it.
    var isReviewPresented = false

    var isModalPresented: Bool {
        (lookedUpCardId != nil && !forcesLookUp) || !ambiguous.isEmpty || isReviewPresented
    }

    /// Writes a staged draft's scan plate and returns its file name. Injected so tests stage
    /// drafts without touching Application Support.
    var savePlate: (Data, String) -> String? = { jpeg, id in
        ScanStagingStore.writePlate(jpeg, draftId: id)
    }

    init(matcher: Matcher, detector: CardDetector, textGate: TextGate, narrowing: CandidateNarrowing,
         staging: ScanStagingStore, store: CatalogStore, fingerThrottle: Int = 4,
         minFocus: Double = 40) {
        // ponytail: minFocus=40 is derived offline (64 good plates ≥182 sharp, 53–319 blurred);
        // re-tune from on-device "heavy frame" logs if real captures gate out.
        self.staging = staging; self.store = store
        self.pipeline = ScanPipeline(detector: detector, textGate: textGate, matcher: matcher,
                                     narrowing: narrowing, fingerThrottle: fingerThrottle,
                                     minFocus: minFocus)
    }

    func run(source: FrameSource) async {
        for await pb in source.stream() {
            // A chooser or a presented look-up card is modal, and `handle` already discards every
            // event while one is up — but the cascade behind that event ran anyway. In look-up
            // mode that is most of a session: the whole time you spend reading the card you just
            // scanned, the phone is grinding OCR + ORB + RANSAC on frames whose results are
            // thrown away on arrival. Skip the work, not just the result.
            let modal = isModalPresented
            if modal {
                source.setIdle(throttle.update(cardVisible: false, modal: true))
                continue
            }
            let out = await pipeline.process(pb)          // runs OFF the main actor
            source.setIdle(throttle.update(cardVisible: !out.noCard, modal: false))
            if out.noCard {
                guidance = Self.idleGuidance; bestGuess = nil; bestGuessName = nil
                confirmations = 0
                continue
            }
            coverage = out.coverage
            noteExamined(poolCount: out.poolCount, confirmations: out.confirmations,
                         needed: out.confirmationsNeeded)
            if let event = out.event { await handle(event) }
        }
    }

    func handle(_ event: ScanEvent) async {
        // The chooser is modal (Tomas, 2026-07-21): once options are on screen, ONLY a user tap
        // (chooseAmbiguous / dismissChooser) may clear them. Ignore every frame event meanwhile —
        // critically the pipeline's quality-gate `.guide`, which is emitted WITHOUT passing through
        // ScanSession, so the session's chooserPending latch never sees it. That stray `.guide`
        // was wiping the chooser after a few blurry/glary frames ("the 4 options went away after
        // 3-5s"). The first `.ambiguous` still gets through — `ambiguous` is empty at that point.
        if !ambiguous.isEmpty { return }
        // A presented look-up card is modal for the same reason the chooser is: the camera keeps
        // running underneath, and a second lock landing while the sheet is up would swap the card
        // out from under you (or, with `.sheet(item:)`, silently fail to re-present). Cleared by
        // `clearLookedUpCard()` on dismiss, which also resets the session.
        //
        // ⚠️ DO NOT narrow this to `isModalPresented`, however tempting the symmetry looks. There is
        // no sheet at all on a borrowed viewfinder, and this guard is still what makes that path
        // correct: it discards events for the few ms between `stage()` setting the id and
        // `ScanView`'s `onChange` Task clearing it, so one card cannot be handed to a trade twice.
        // The throttle asks "is something on screen" and must exclude a handoff; this asks "has a
        // card already been claimed" and must not. Same field, two different questions — which is
        // the overload that produced the #154/#155 collision in the first place (#156).
        if lookedUpCardId != nil { return }
        switch event {
        case .idle: break
        case .guide(let g):
            // Resolve the name only when the candidate actually changes — this is a DB read inside
            // the per-frame path, and the guess holds steady for the whole confirmation streak.
            //
            // A nil guess must NOT wipe the name: the quality gate emits `.guide(nil)` for any
            // blurry or glary frame without touching the session's streak, so clearing here made
            // the caption fall back to "Checking N cards…" while the ring stayed exactly where it
            // was. The iPad gates frames often (focus ran 40–662 against a floor of 40), so the
            // caption flickered against a stationary ring. The session's streak is the authority
            // on whether we are still confirming something; a single bad frame is not.
            if let g, g != bestGuess { bestGuessName = (try? store.card(id: g))??.name }
            bestGuess = g; ambiguous = []; guidance = g == nil ? "Scanning…" : "Hold steady"
        case .ambiguous(let ids):
            ambiguous = ids.map(chooserOption)
            guidance = "Scanning paused — pick your card"
        case .lock(let cardId): await stage(cardId: cardId)
        }
    }

    /// Resolve a confident lock. In look-up mode that means publishing the card for the view to
    /// present and nothing else; otherwise it stages a reviewable draft (heuristic variant from
    /// catalog rarity, blind-price snapshot from `price_latest.raw_usd`). Never writes an owned
    /// entry. Both lock paths — the automatic one and the ambiguity chooser — funnel through here,
    /// so the mode can't be honoured on one and missed on the other.
    private func stage(cardId: String) async {
        ambiguous = []
        let card = try? store.card(id: cardId)
        guard !isLookingUp else {
            lookedUpCardId = cardId
            guidance = Self.idleGuidance
            return
        }
        // Price the draft at the condition it's actually being staged at, through the same
        // resolver the review screen and the tin use. A raw-market snapshot would leave the
        // tray's running total quoting mint money for a stack you've just told it is played —
        // and that total is the number you watch while scanning, so it has to be the honest one.
        // Three single-card indexed reads, against a per-frame ORB match that dwarfs them.
        let variant = CardVariant.defaultFor(rarity: card?.rarity)
        let price = GroupStats.unitPrice(
            condition: stagingCondition, variant: variant,
            price: try? store.price(cardId: cardId),
            variants: (try? store.variantPrices(cardId: cardId)) ?? [],
            conditions: (try? store.conditionPrices(cardId: cardId)) ?? [],
            matrix: (try? store.matrixPrices(cardId: cardId)) ?? [])
        // The plate is saved under the draft's own id, so the picture and the row can never be
        // mismatched. Nil is normal: the card can leave the frame between the lock and here.
        let id = UUID().uuidString
        let plateFile = await pipeline.currentPlate().flatMap { savePlate($0, id) }
        let draft = ScanDraft(id: id, cardId: cardId,
                              variant: variant, condition: stagingCondition,
                              qty: 1, addedAt: Date(), priceUsdSnapshot: price,
                              acquiredVia: stagingVia, plateFile: plateFile)
        staging.append(draft)
        // The card's name, not its catalog id — this line read "Added swsh7-215 — next card".
        guidance = "Added \(card?.name ?? cardId) — next card"
        // Announce it, and stop confirming a card that is already in the tray: `bestGuess` used to
        // survive the lock, so the viewfinder went straight back to "Hold steady" on the very card
        // it had just captured.
        bestGuess = nil; bestGuessName = nil
        lastAdded = card?.name ?? cardId
        lastAddedClear?.cancel()
        lastAddedClear = Task { [weak self] in
            try? await Task.sleep(for: Self.addedLinger)
            guard !Task.isCancelled else { return }
            self?.lastAdded = nil
        }
    }

    /// The look-up card has been shown and dismissed: clear it and wipe the scanner back to a
    /// clean slate, so the very next frame can read the next card — or the same one again.
    func clearLookedUpCard() async {
        lookedUpCardId = nil
        await reset()
    }

    /// Resolve a chooser id to the display metadata the user recognizes. Failed lookups fall
    /// back to nil fields (the tile shows the id) rather than dropping the option.
    private func chooserOption(id: String) -> ChooserOption {
        let card = (try? store.card(id: id)) ?? nil
        let set = (card?.setId).flatMap { (try? store.set(id: $0)) ?? nil }
        return ChooserOption(id: id, card: card, setName: set?.name,
                             year: (set?.releaseDate).map { String($0.prefix(4)) },
                             setTotal: set?.total)
    }

    func chooseAmbiguous(cardId: String) async {
        await stage(cardId: cardId)
        await pipeline.acknowledgeChoice(cardId: cardId)
    }

    /// "None of these — keep scanning."
    func dismissChooser() async {
        ambiguous = []
        guidance = "Scanning…"
        await pipeline.dismissChooser()
    }

    /// Manual "Reset": wipe the scanner back to a clean slate (votes, lock, chooser, the
    /// per-card suppression, AND a presented look-up card). Leaves the staging tray untouched.
    ///
    /// `lookedUpCardId` was missing from this list, and it is one of the two fields `handle(_:)`
    /// uses to drop every incoming event. Stuck non-nil — a look-up lock whose sheet never
    /// presented, or a mode switch while it was set — the scanner goes permanently deaf: the
    /// pipeline keeps emitting locks and the model discards all of them. Diagnosed on an iPad
    /// 2026-07-27 from a ScanDiag dump showing SEVEN locks on the same card, none of which
    /// reached the tray. An escape hatch documented as restoring a clean slate has to clear
    /// everything that can wedge the scanner, or the user has no way out at all.
    func reset() async {
        ambiguous = []
        bestGuess = nil
        bestGuessName = nil
        confirmations = 0
        lastAddedClear?.cancel(); lastAdded = nil
        lookedUpCardId = nil
        guidance = Self.idleGuidance
        await pipeline.reset()
    }
    func reject(_ draft: ScanDraft) async {
        await pipeline.reject(cardId: draft.cardId)
        staging.remove(id: draft.id)
    }
}
