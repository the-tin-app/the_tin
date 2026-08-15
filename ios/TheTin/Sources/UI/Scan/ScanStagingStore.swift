import Foundation
import Observation

/// A scanned card awaiting review/commit. Lives only in the local staging store — never
/// an owned `CollectionEntry` until the user routes it.
struct ScanDraft: Identifiable, Equatable, Codable {
    let id: String
    let cardId: String
    var variant: CardVariant
    var condition: CardCondition
    var qty: Int
    let addedAt: Date
    var priceUsdSnapshot: Double?   // blind at scan time; repriced variant/condition-aware in review
    /// How these cards were acquired, captured at scan time from the scanner's picker.
    /// Optional: `ScanDraft` is Codable and persists to disk, so a defaulted non-optional would
    /// make every staged tray written before this existed fail to decode.
    var acquiredVia: AcquiredVia? = nil
    /// Border ratios the user has confirmed by dragging the lines in the centring editor. Nil
    /// means "not measured", never "measured and we're unsure" — an automatic reading is only
    /// ever a starting position for the editor, never a value that reaches the row (see
    /// `Centering`). Optional for the same decode reason as `acquiredVia`.
    var centering: Centering? = nil
    /// File name (not path) of this draft's scan plate inside `ScanStagingPaths.platesDir`, the
    /// picture the centring editor draws its lines on. Nil for drafts staged before this existed,
    /// for look-ups, and whenever the card left the frame before the lock resolved.
    var plateFile: String? = nil
}

/// Local, ephemeral holding area for scanned drafts. NOT part of `collection.entries`, so
/// staged cards never feed For-You until committed. Persists to disk via an injected sink
/// (Task 3); `.inMemory()` uses a no-op sink for tests.
@MainActor @Observable
final class ScanStagingStore {
    private(set) var drafts: [ScanDraft] = []
    private let persist: ([ScanDraft]) -> Void

    init(initial: [ScanDraft] = [], persist: @escaping ([ScanDraft]) -> Void) {
        self.drafts = initial
        self.persist = persist
    }

    static func inMemory() -> ScanStagingStore { ScanStagingStore(persist: { _ in }) }

    var totalUsd: Double { drafts.reduce(0) { $0 + ($1.priceUsdSnapshot ?? 0) } }

    func append(_ draft: ScanDraft) { drafts.insert(draft, at: 0); persist(drafts) }

    /// Removing a draft deletes its plate. A scan plate is ~100 KB and nothing else references it,
    /// so leaving them behind would grow Application Support without bound for the whole life of
    /// the install — every scan ever taken, including the ones filed or cleared minutes later.
    func remove(id: String) {
        drafts.removeAll { $0.id == id && discardPlate($0) }
        persist(drafts)
    }

    func clear() {
        drafts.forEach { _ = discardPlate($0) }
        drafts.removeAll()
        persist(drafts)
    }

    /// Deletes a draft's plate file. Always returns true so it can ride along inside `removeAll`.
    @discardableResult
    private func discardPlate(_ draft: ScanDraft) -> Bool {
        if let name = draft.plateFile { deletePlate(name) }
        return true
    }

    /// Injected so the in-memory store touches no disk. The persisted store deletes for real.
    var deletePlate: (String) -> Void = { _ in }

    func updateCentering(id: String, _ c: Centering) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[i].centering = c; persist(drafts)
    }

    func updateVariant(id: String, _ v: CardVariant) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[i].variant = v; persist(drafts)
    }
    func updateCondition(id: String, _ c: CardCondition) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[i].condition = c; persist(drafts)
    }

    /// Recompute every draft's price snapshot. The review screen passes a variant/condition-aware
    /// resolver (GroupStats.unitPrice over its batch-fetched prices) on open and after each edit.
    /// Tray total and review total both sum these snapshots, so they always agree.
    func reprice(_ resolve: (ScanDraft) -> Double?) {
        guard !drafts.isEmpty else { return }
        for i in drafts.indices { drafts[i].priceUsdSnapshot = resolve(drafts[i]) }
        persist(drafts)
    }
}

struct ScanStagingPaths {
    var fileURL: URL
    /// Scan plates, one JPEG per draft, beside the JSON. A directory rather than base64 in the
    /// draft: the JSON is rewritten in full on every mutation — every reprice, every variant
    /// edit — and inlining ~100 KB per draft would make a 50-card tray a 5 MB rewrite per tap.
    var platesDir: URL

    /// `platesDir` defaults to a folder beside the JSON, so a caller that only knows where the
    /// staging file goes — every test that existed before plates did — still gets a consistent
    /// pair rather than plates landing in Application Support during a test run.
    init(fileURL: URL, platesDir: URL? = nil) {
        self.fileURL = fileURL
        self.platesDir = platesDir
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("scan-plates",
                                                                          isDirectory: true)
    }

    static func `default`() -> ScanStagingPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ScanStagingPaths(fileURL: base.appendingPathComponent("scan-staging.json"),
                                platesDir: base.appendingPathComponent("scan-plates", isDirectory: true))
    }
}

extension ScanStagingStore {
    /// Disk-backed staging store. Loads persisted drafts on init and rewrites the file
    /// (atomic) on every mutation. Failures degrade to in-memory (never crash scanning).
    static func persisted(paths: ScanStagingPaths = .default()) -> ScanStagingStore {
        let loaded: [ScanDraft] = (try? Data(contentsOf: paths.fileURL))
            .flatMap { try? JSONDecoder().decode([ScanDraft].self, from: $0) } ?? []
        let store = ScanStagingStore(initial: loaded, persist: { drafts in
            try? FileManager.default.createDirectory(
                at: paths.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(drafts) {
                try? data.write(to: paths.fileURL, options: .atomic)
            }
        })
        store.deletePlate = { name in
            try? FileManager.default.removeItem(at: paths.platesDir.appendingPathComponent(name))
        }
        // Orphans: a plate whose draft is gone. The pairing can break either way round — a crash
        // between writing the plate and persisting the draft, or a staging JSON that failed to
        // decode and reset to empty while the plates survived. Neither is reachable from the UI,
        // so nothing else would ever delete them.
        let live = Set(loaded.compactMap(\.plateFile))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.platesDir.path)) ?? []
        where !live.contains(name) {
            try? FileManager.default.removeItem(at: paths.platesDir.appendingPathComponent(name))
        }
        return store
    }

    /// Writes a scan plate for `draftId` and returns its file name, or nil if it couldn't be
    /// written — in which case the draft simply has no plate and the editor offers no picture.
    static func writePlate(_ jpeg: Data, draftId: String,
                           paths: ScanStagingPaths = .default()) -> String? {
        try? FileManager.default.createDirectory(at: paths.platesDir, withIntermediateDirectories: true)
        let name = "\(draftId).jpg"
        do {
            try jpeg.write(to: paths.platesDir.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }
}
