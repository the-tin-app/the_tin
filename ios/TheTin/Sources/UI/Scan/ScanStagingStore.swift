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
    func remove(id: String) { drafts.removeAll { $0.id == id }; persist(drafts) }
    func clear() { drafts.removeAll(); persist(drafts) }

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
    static func `default`() -> ScanStagingPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ScanStagingPaths(fileURL: base.appendingPathComponent("scan-staging.json"))
    }
}

extension ScanStagingStore {
    /// Disk-backed staging store. Loads persisted drafts on init and rewrites the file
    /// (atomic) on every mutation. Failures degrade to in-memory (never crash scanning).
    static func persisted(paths: ScanStagingPaths = .default()) -> ScanStagingStore {
        let loaded: [ScanDraft] = (try? Data(contentsOf: paths.fileURL))
            .flatMap { try? JSONDecoder().decode([ScanDraft].self, from: $0) } ?? []
        return ScanStagingStore(initial: loaded, persist: { drafts in
            try? FileManager.default.createDirectory(
                at: paths.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(drafts) {
                try? data.write(to: paths.fileURL, options: .atomic)
            }
        })
    }
}
