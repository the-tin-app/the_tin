import CoreGraphics
import Foundation

/// One pocket's answer.
struct BinderSlotEntry: Codable, Equatable, Identifiable {
    let slot: BinderSlot
    /// nil means unresolved — either nothing separated cleanly (see `options`) or nothing matched at
    /// all. A pocket with no detection has no entry, and renders as an empty pocket.
    var cardId: String?
    /// The chooser's four candidates when this pocket could not auto-resolve. Held rather than
    /// recomputed: tap-to-resolve happens minutes later, standing at a counter, and re-running the
    /// match would mean holding the photograph's plates.
    var options: [String] = []
    var inliers: Int = 0
    var onWishlist: Bool = false
    /// Which tile photograph this came from, and where in it. Together they are the verification
    /// crop — the answer to "is that actually the card in the pocket", which synthetic catalog art
    /// cannot give you.
    var tile: String = ""
    /// Normalized to the tile image, top-left origin.
    var crop: CGRect = .zero
    /// Why this pocket couldn't be read, when that is the reason it is unresolved. ⚠️ A real `Optional`,
    /// not a defaulted non-optional: a defaulted property still makes synthesized `Decodable` DEMAND the
    /// key, so every scan written before this field existed would fail to decode. Same convention as
    /// `CollectionEntry.forTrade` and `BackupSnapshot.setGoals`.
    var unreadable: String?
    /// The user picked this, from the chooser or by hand.
    ///
    /// ⚠️ Load-bearing, not bookkeeping: a 3×3 or 5×5 binder photographs one row and one column
    /// TWICE, so a pocket the user has already corrected can still receive a second machine
    /// observation. Without this the correction is silently overwritten by the thing it corrected.
    var byHand: Bool = false

    var id: BinderSlot { slot }
    var isResolved: Bool { cardId != nil }
}

/// A captured binder. **A cache, not a document** — and the distinction is what keeps a one-way door
/// shut. It lives in `Caches/`, it is deleted after a day, and there is deliberately no backup, no
/// restore, no sync, no CSV and no migration path. A shop has replaced several cards by tomorrow, so
/// the data is stale anyway; if the shape of this type changes next release the worst case is
/// someone loses a scan they would have lost by morning.
struct BinderScan: Codable, Equatable {
    var shape: BinderShape
    var createdAt: Date
    /// How many pages have been photographed. Pages are 0-indexed and contiguous.
    var pagesCaptured: Int = 0
    var entries: [BinderSlotEntry] = []

    func entry(_ slot: BinderSlot) -> BinderSlotEntry? { entries.first { $0.slot == slot } }

    /// Upserts one pocket. Four clauses, each with its own reason — this is where the overlap between
    /// tiles turns into a vote instead of a race.
    mutating func put(_ entry: BinderSlotEntry) {
        guard let i = entries.firstIndex(where: { $0.slot == entry.slot }) else {
            entries.append(entry); return
        }
        let held = entries[i]
        if entry.byHand { entries[i] = entry; return }          // the user's answer always wins…
        if held.byHand { return }                               // …and is never overwritten
        if held.tile == entry.tile { entries[i] = entry; return } // a re-shot tile replaces its own
        if entry.inliers > held.inliers { entries[i] = entry }   // otherwise the better look wins
    }
}

/// Where a captured binder lives between the shop and the sofa: `Caches/VirtualBinder/`, holding one
/// `scan.json` and one downscaled JPEG per tile photograph.
///
/// `Caches/` rather than `Application Support/` on purpose. The OS may evict it, and that is the
/// correct behaviour for something with a one-day life — it also means nothing here is a contract
/// with a shipped build, which is what makes the format free to change.
struct BinderCache {
    let root: URL
    /// Delete-if-stale on load. Tomas's reasoning: by the next day a shop has likely replaced
    /// several cards, so a scan older than this is misinformation, not history.
    var lifetime: TimeInterval = 24 * 60 * 60

    static let shared = BinderCache(
        root: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
               ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("VirtualBinder", isDirectory: true))

    private var scanURL: URL { root.appendingPathComponent("scan.json") }
    func tileURL(_ tileId: String) -> URL {
        root.appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent("\(tileId).jpg")
    }

    /// The saved scan, or nil if there isn't one, it has expired, or it can't be decoded. Every one
    /// of those three cases deletes the directory: a scan that cannot be read is not worth a
    /// migration path, and leaving it on disk means paying the decode failure again every launch.
    func load(now: Date = Date()) -> BinderScan? {
        guard let data = try? Data(contentsOf: scanURL),
              let scan = try? JSONDecoder().decode(BinderScan.self, from: data) else {
            if FileManager.default.fileExists(atPath: root.path) { clear() }
            return nil
        }
        guard now.timeIntervalSince(scan.createdAt) < lifetime else { clear(); return nil }
        return scan
    }

    func save(_ scan: BinderScan) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(scan) else { return }
        try? data.write(to: scanURL, options: .atomic)
    }

    func writeTile(_ tileId: String, jpeg: Data) {
        let url = tileURL(tileId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? jpeg.write(to: url, options: .atomic)
    }

    func clear() { try? FileManager.default.removeItem(at: root) }
}
