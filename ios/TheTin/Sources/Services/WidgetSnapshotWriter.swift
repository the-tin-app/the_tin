import Foundation
import WidgetKit

/// Debounced writer of widget-snapshot.json into the App Group container. The TheTinWidgets
/// extension reads the file; `reload()` pokes WidgetKit so timelines re-render (widget timelines
/// are static — this call is the only refresh path).
@MainActor
final class WidgetSnapshotWriter {
    private let fileURL: URL?
    private let debounce: Duration
    private let reload: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(containerURL: URL? = FileManager.default
             .containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupId),
         debounce: Duration = .seconds(2),
         reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.fileURL = containerURL.map(WidgetShared.snapshotURL(container:))
        self.debounce = debounce
        self.reload = reload
    }

    /// Coalesces bursts (bulk edits, price reloads) into one write + one reload.
    func schedule(_ snapshot: WidgetSnapshot) {
        guard let fileURL else { return }  // no App Group container → silently do nothing
        pending?.cancel()
        pending = Task { [debounce, reload] in
            try? await Task.sleep(for: debounce)   // throws CancellationError when superseded
            guard !Task.isCancelled else { return }
            guard let data = try? WidgetShared.encoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
            reload()
        }
    }
}
