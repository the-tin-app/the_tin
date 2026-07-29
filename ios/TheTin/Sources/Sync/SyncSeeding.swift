import Foundation

/// What to do the first time this device meets the sync zone.
enum SeedDecision: Equatable {
    /// The zone is empty — this device's collection becomes the shared one. No prompt.
    case seedZone
    /// This device is empty — take what's already there. No prompt. This is what makes a new or
    /// restored device just work.
    case pullDown
    /// Both hold cards and this device has never synced. One sheet, with real counts rather than
    /// adjectives; the loser is replaced, after a backup snapshot.
    case ask(localCount: Int, remoteCount: Int)
    /// Already seeded — normal two-way operation.
    case none
}

enum SyncSeeding {
    /// The whole first-run decision, as a table over `zone empty? × local empty?`.
    ///
    /// `alreadySeeded` (the `syncSeeded` UserDefaults flag) is checked FIRST and unconditionally:
    /// it is the entire guarantee that no path asks twice and that no path silently replaces a
    /// non-empty tin on a device that already made its choice.
    static func decide(localCount: Int, remoteCount: Int, alreadySeeded: Bool) -> SeedDecision {
        if alreadySeeded { return .none }
        if remoteCount == 0 { return .seedZone }   // covers both-empty: a no-op that sets the flag
        if localCount == 0 { return .pullDown }
        return .ask(localCount: localCount, remoteCount: remoteCount)
    }
}
