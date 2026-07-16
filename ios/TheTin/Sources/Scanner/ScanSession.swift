import Foundation

struct FrameObservation {
    let candidates: [(id: String, inliers: Int)]
    let coverage: Double
    let cardPresent: Bool
    var gated: Bool = false
    // OCR-consistency data per candidate id, keyed the same as `candidates`. `nil` means OCR
    // consistency was not evaluated this frame → the lock gate falls back to visual-only
    // locking (backward compatible with the interim pipeline, which still passes nil until
    // F1b wires the real computation).
    var consistency: [String: CandidateConsistency]? = nil
}

/// Per-candidate OCR/twin agreement used to gate a confident auto-lock. All three must hold
/// for the visual winner, else the lock gate falls back to a chooser instead of locking wrong.
struct CandidateConsistency: Equatable {
    let nameAgrees: Bool      // winner's catalog basename appears in the OCR text
    let denomOk: Bool         // OCR denominator absent OR == winner set's printed_total
    let hasTwinInPool: Bool   // winner has a card_twin also present in the candidate pool
}

struct LockConfig {
    // nf=650 absolute inlier floor ≈ 0.03·650; re-tune on the real pack in Phase H.
    var tLock: Int = 20
    var ratioR: Double = 1.3   // measured lock margin
    var stabilityK: Int = 3
    var coverageMin: Double = 0.8
    var gatedConfirmFloor: Int = 12
    var graceMisses: Int = 12   // tolerate this many consecutive no-card frames before wiping accumulation
    // ponytail: ≈7s at the observed heavy-frame cadence (~2.3/s, ScanDiag 2026-07-15);
    // retune from ScanDiag timing if the cadence shifts.
    var chooserDeadlineFrames: Int = 16   // heavy frames without a lock before forcing the chooser
}

enum ScanEvent: Equatable {
    case idle
    case guide(bestGuess: String?)
    case ambiguous([String])
    case lock(cardId: String)
}

final class ScanSession {
    private let config: LockConfig
    private var accum: [String: Int] = [:]
    private var leader: String?
    private var leaderStreak = 0
    private var locked = false
    private var lockedCardId: String?   // which card the latch belongs to (drives swap release)
    private var swapStreak = 0          // consecutive latched frames dominated by a DIFFERENT card
    private var missStreak = 0   // consecutive no-card frames (grace against transient dropouts)
    private var presentFrames = 0   // heavy frames since acquisition (drives the chooser deadline)
    private var suppressed: Set<String> = []

    init(config: LockConfig = LockConfig()) { self.config = config }

    func reject(cardId: String) { suppressed.insert(cardId); resetAccumulation() }

    /// Latch as if a lock occurred — used when the user manually resolves an `.ambiguous`
    /// chooser, so the same physical card cannot auto-lock again until it leaves the frame
    /// or a different card takes its place (swap release).
    func acknowledge(cardId: String) { locked = true; lockedCardId = cardId }

    /// "None of these — keep scanning": drop the frozen chooser and start over on whatever is
    /// under the camera. Deliberately does NOT suppress the shown options — a shown option may
    /// be the truth of a LATER card (binder duplicates), and the user may simply have mis-aimed.
    func dismissChooser() { resetAccumulation() }

    private func resetAccumulation() {
        accum.removeAll(); leader = nil; leaderStreak = 0
        locked = false; lockedCardId = nil; swapStreak = 0; presentFrames = 0
    }

    /// Surface a frozen chooser: options must not reshuffle while the user decides, so every
    /// chooser latches like a lock (Tomas, 2026-07-15). The swap-release path frees the latch
    /// when the user moves on to a different card without picking.
    private func chooser(_ ranked: [(key: String, value: Int)]) -> ScanEvent {
        locked = true; lockedCardId = ranked.first?.key
        return .ambiguous(ranked.prefix(4).map { $0.key })
    }

    func ingest(_ obs: FrameObservation) -> ScanEvent {
        if !obs.cardPresent {
            // Tolerate brief detector dropouts: a hand-held card at live frame rate flickers
            // out of Vision's rectangle detector for the odd frame, and resetting on every
            // miss would wipe a strong accumulation before the lock streak can build (the card
            // matches but never locks). Only wipe once the card has been gone for a sustained
            // run of frames (genuinely removed / swapped).
            missStreak += 1
            if missStreak >= config.graceMisses { resetAccumulation() }
            return .idle
        }
        missStreak = 0
        if locked {
            // Hold until the card leaves the frame — but over a binder the next pocket slides
            // in with NO no-card gap, so the graceMisses unlatch alone can never fire (2026-07-15
            // binder failure round 2: first card locked, every card after returned .idle).
            // Swap release: if a clearly DIFFERENT card dominates (this frame's strongest
            // candidate clears the lock floor and isn't the latched card) for stabilityK
            // consecutive heavy frames, the card was swapped — wipe the old accumulation and
            // process this frame fresh. Weak flickers and the latched card itself hold the latch.
            let strongest = obs.candidates.filter { !suppressed.contains($0.id) }
                .max { $0.inliers < $1.inliers }
            if let s = strongest, s.id != lockedCardId, s.inliers >= config.tLock {
                swapStreak += 1
                if swapStreak < config.stabilityK { return .idle }
                resetAccumulation()   // falls through: this frame starts the new card's streak
            } else {
                swapStreak = 0
                return .idle
            }
        }

        presentFrames += 1
        for c in obs.candidates where !suppressed.contains(c.id) {
            accum[c.id] = max(accum[c.id] ?? 0, c.inliers)
        }
        let ranked = accum.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return .guide(bestGuess: nil) }

        if top.key == leader { leaderStreak += 1 } else { leader = top.key; leaderStreak = 1 }

        let second = ranked.dropFirst().first?.value ?? 0
        let ratio = Double(top.value) / Double(max(second, 1))
        let separated = ratio >= config.ratioR
        let strong = top.value >= config.tLock
        let stable = leaderStreak >= config.stabilityK
        let covered = obs.coverage >= config.coverageMin

        if strong && separated && stable && covered {
            if let cons = obs.consistency {                 // OCR consistency evaluated this frame → gate is active
                if let f = cons[top.key] {
                    if f.nameAgrees && f.denomOk && !f.hasTwinInPool {
                        locked = true; lockedCardId = top.key
                        return .lock(cardId: top.key)
                    }
                    return chooser(ranked)   // inconsistent OR twin-in-pool → chooser, NOT wrong-lock
                }
                // Leader wasn't evaluated THIS frame (OCR hiccup shrank the pool / early-exit
                // stopped before it). Nothing contradicts it — keep guiding; a later frame
                // that does evaluate it will lock or chooser.
                return .guide(bestGuess: top.key)
            }
            locked = true; lockedCardId = top.key
            return .lock(cardId: top.key)                    // no consistency data → visual-only (backward compat)
        }
        if strong && stable && covered && !separated {
            return chooser(ranked)
        }
        // Holo defense: a gated candidate that's weak (below tLock) but above the confirm
        // floor is surfaced for user confirmation rather than dropped — holo/reverse-holo
        // often land here even after the nf=1000 rebuild.
        if obs.gated && stable && covered && top.value >= config.gatedConfirmFloor && top.value < config.tLock {
            return chooser(ranked)
        }
        // Scan deadline (Tomas, 2026-07-15): after ~7s on a card with no lock, stop spinning —
        // surface the accumulated best options as a frozen chooser and let the user decide.
        if presentFrames >= config.chooserDeadlineFrames {
            return chooser(ranked)
        }
        return .guide(bestGuess: top.key)
    }
}
