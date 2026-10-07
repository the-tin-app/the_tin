import Foundation
import Observation

struct BinderPaths {
    var fileURL: URL
    static func `default`() -> BinderPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BinderPaths(fileURL: base.appendingPathComponent("binders.json"))
    }
}

/// An array element that decodes to nil instead of failing the whole array.
///
/// This is the half of the `WantPriority` fix that matters here: lose one binder, never all of
/// them. Without it a single unreadable record makes `load` return `[:]`, and the next write
/// persists that emptiness over the file — the `wants.json` bug, one type along.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// The binder layouts, keyed by the divider each one lays out.
///
/// Its own file rather than a field on `CardGroup`, for two reasons: a master-set layout is ~400
/// slots and `CardGroup` is `Equatable` and diffed by SwiftUI on every group render; and
/// `collection.json` is the hottest write path in the app, which a layout edit has no business
/// touching. Same file-per-concern shape as `wants.json` and `set-goals.json`.
///
/// Deliberately modelled on `SetGoalsModel`, down to the optimistic-write-with-rollback: one small
/// whole-file write, no repository, no streams.
@MainActor @Observable
final class BinderLayoutsModel {
    private(set) var layouts: [String: BinderLayout] = [:]
    private let fileURL: URL
    private var unreadable = false
    /// Routes write failures into the same alert sink as collection/wishlist writes.
    var onWriteError: ((String) -> Void)?
    /// Fired after a successful write. `BackupService` uses it in place of a stream.
    var onChange: (() -> Void)?

    init(paths: BinderPaths = .default()) {
        self.fileURL = paths.fileURL
        let data = try? Data(contentsOf: paths.fileURL)
        let parsed = data.flatMap { Self.parse($0) }
        // A non-empty file we could not parse AT ALL is not the same as no file at all.
        self.unreadable = (data?.isEmpty == false) && parsed == nil
        self.layouts = parsed ?? [:]
    }

    /// nil = the bytes were not a readable list of layouts at all. A list containing one unreadable
    /// LAYOUT is not that case: the bad record is dropped and its siblings survive.
    static func parse(_ data: Data) -> [String: BinderLayout]? {
        guard let list = try? JSONDecoder().decode([Lenient<BinderLayout>].self, from: data) else {
            return nil
        }
        // Last writer wins on a duplicated groupId. `uniqueKeysWithValues` TRAPS there, and this is
        // untrusted input — a hand-edited file or a restored backup — so that trap is a crash on
        // every launch until the file is deleted by hand.
        return Dictionary(list.compactMap(\.value).map { ($0.groupId, $0.normalized()) },
                          uniquingKeysWith: { _, later in later })
    }

    /// Every layout, ordered — what the backup snapshot writes.
    var all: [BinderLayout] { layouts.values.sorted { $0.groupId < $1.groupId } }

    func layout(for groupId: String) -> BinderLayout? { layouts[groupId] }

    func save(_ layout: BinderLayout) { mutate { $0[layout.groupId] = layout.normalized() } }

    /// Called when a divider is deleted. An orphaned layout is invisible forever and would
    /// silently reappear if the id were ever reused.
    func remove(groupId: String) { mutate { $0[groupId] = nil } }

    /// Restores a backup's layouts wholesale (mirrors `SetGoalsModel.replaceAll`).
    func replaceAll(_ list: [BinderLayout]) {
        mutate { dict in
            dict = Dictionary(list.map { ($0.groupId, $0.normalized()) },
                              uniquingKeysWith: { _, later in later })
        }
    }

    /// Optimistic, rolled back if the write fails, so the UI never shows a layout that wouldn't
    /// survive a relaunch.
    private func mutate(_ change: (inout [String: BinderLayout]) -> Void) {
        let previous = layouts
        change(&layouts)
        do { try persist(); onChange?() } catch {
            layouts = previous
            onWriteError?("Couldn't update your binder — nothing was changed. Check free storage and try again.")
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if unreadable {
            // Keep what we could not read rather than writing over it. Best effort — if the rename
            // fails there is nothing better to do than carry on, and one sidecar is enough: the
            // first unreadable version is the one worth having.
            try? FileManager.default.moveItem(at: fileURL,
                                              to: fileURL.appendingPathExtension("corrupt"))
            unreadable = false
        }
        // Sorted so the file is stable between writes and diffs cleanly in a backup.
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}
