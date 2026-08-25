import Foundation
import Observation

struct BinderPaths {
    var fileURL: URL
    static func `default`() -> BinderPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BinderPaths(fileURL: base.appendingPathComponent("binders.json"))
    }
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
    /// Routes write failures into the same alert sink as collection/wishlist writes.
    var onWriteError: ((String) -> Void)?
    /// Fired after a successful write. `BackupService` uses it in place of a stream.
    var onChange: (() -> Void)?

    init(paths: BinderPaths = .default()) {
        self.fileURL = paths.fileURL
        self.layouts = Self.load(from: paths.fileURL)
    }

    /// A decode failure is an empty model, never a crash — the same forward-only leniency
    /// `WantPriority` documents, and for the same reason: a build that can't read the file must
    /// not be the reason the user's work disappears with no warning.
    static func load(from url: URL) -> [String: BinderLayout] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([BinderLayout].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.groupId, $0.normalized()) })
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
            dict = Dictionary(uniqueKeysWithValues: list.map { ($0.groupId, $0.normalized()) })
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
        // Sorted so the file is stable between writes and diffs cleanly in a backup.
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}
