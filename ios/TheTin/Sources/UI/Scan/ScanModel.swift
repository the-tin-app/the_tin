import Observation
import CoreVideo
import Foundation
import os

/// Outcome of processing a single frame through the off-main `ScanPipeline`.
struct FrameOutcome { let coverage: Double; let noCard: Bool; let event: ScanEvent? }

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

    func process(_ pb: CVPixelBuffer) -> FrameOutcome {
        frameIndex += 1
        var timer = StageTimer()
        if frameIndex % fingerThrottle != 0 {
            // Light frame: presence only — feeds the session's grace/miss accounting without
            // paying rectification + orientation OCR for a plate we'd throw away.
            if timer.measure("presence", { detector.cardPresent(pixelBuffer: pb) }) {
                return FrameOutcome(coverage: 0, noCard: false, event: nil)
            }
            _ = session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
            return FrameOutcome(coverage: 0, noCard: true, event: nil)
        }
        guard let frame = timer.measure("detect", { detector.detect(pixelBuffer: pb) }) else {
            _ = session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
            return FrameOutcome(coverage: 0, noCard: true, event: nil)
        }
        // Single-frame quality gate: only fingerprint a sharp, low-glare frame. No cross-frame
        // fusion — the hand-held quad jitters, so per-pixel fusion across frames tears the plate
        // and destroys ORB structure (Plan 5). Temporal robustness comes from ScanSession voting.
        guard frame.focus >= minFocus, frame.glareCoverage <= maxGlare else {
            // A gated frame must still surface an event: with no event the guidance stays stuck
            // on the initial "Frame the card inside the box" even though a card IS detected —
            // which is exactly how the 2026-07-15 binder failure stayed invisible on device.
            return FrameOutcome(coverage: 0, noCard: false, event: .guide(bestGuess: nil))
        }
        guard let query = timer.measure("fingerprint", {
            fingerprint(frame.pixels, frame.width, frame.height, frame.bytesPerRow) }) else {
            return FrameOutcome(coverage: 0, noCard: false, event: nil)
        }
        // F1b: full-plate OCR (E1) → ranked narrowing pool (E2) → RANSAC-confirm over the pool
        // → per-candidate OCR/twin consistency → ScanSession's F1 lock gate. Replaces the C1
        // interim `matcher.allCardIds` fallback.
        let fields = timer.measure("ocr") { TextGate.extract(plate: frame) }
        let pool = timer.measure("pool") { narrowing.pool(fields: fields) }
        let poolSet = Set(pool)
        let results = timer.measure("match") { (try? matcher.matchRanked(query: query, rankedIds: pool)) ?? [] }
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
        #if DEBUG
        ScanDiag.dump(frame: frame, fields: fields, pool: pool, results: results, event: event)
        #endif
        return FrameOutcome(coverage: 1.0, noCard: false, event: event)
    }

    func acknowledgeChoice(cardId: String) { session.acknowledge(cardId: cardId) }
    func dismissChooser() { session.dismissChooser() }
    func reject(cardId: String) { session.reject(cardId: cardId) }
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

    var guidance: String = "Frame the card inside the box"
    var coverage: Double = 0
    var bestGuess: String?
    var ambiguous: [ChooserOption] = []

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
            let out = await pipeline.process(pb)          // runs OFF the main actor
            if out.noCard { guidance = "Frame the card inside the box"; bestGuess = nil; continue }
            coverage = out.coverage
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
        switch event {
        case .idle: break
        case .guide(let g): bestGuess = g; ambiguous = []; guidance = g == nil ? "Scanning…" : "Hold steady"
        case .ambiguous(let ids):
            ambiguous = ids.map(chooserOption)
            guidance = "Scanning paused — pick your card"
        case .lock(let cardId): stage(cardId: cardId)
        }
    }

    /// Stage a confident lock as a reviewable draft. Heuristic variant from catalog rarity;
    /// blind-price snapshot from `price_latest.raw_usd`. Never writes an owned entry.
    private func stage(cardId: String) {
        let rarity = (try? store.card(id: cardId))?.rarity
        let price = (try? store.price(cardId: cardId))?.rawUsd
        let draft = ScanDraft(id: UUID().uuidString, cardId: cardId,
                              variant: .defaultFor(rarity: rarity), condition: .nm,
                              qty: 1, addedAt: Date(), priceUsdSnapshot: price)
        staging.append(draft)
        ambiguous = []
        guidance = "Added \(cardId) — next card"
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
        stage(cardId: cardId)
        await pipeline.acknowledgeChoice(cardId: cardId)
    }

    /// "None of these — keep scanning."
    func dismissChooser() async {
        ambiguous = []
        guidance = "Scanning…"
        await pipeline.dismissChooser()
    }
    func reject(_ draft: ScanDraft) async {
        await pipeline.reject(cardId: draft.cardId)
        staging.remove(id: draft.id)
    }
}
