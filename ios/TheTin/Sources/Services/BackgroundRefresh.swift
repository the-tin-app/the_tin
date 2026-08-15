import BackgroundTasks
import Foundation

/// Opportunistic background catalog refresh (wishlist price alerts spec — best-effort by
/// design; foreground updates fire the same diff, so the copy never promises real-time).
/// Two-task split: a cheap BGAppRefreshTask polls the manifest; when a newer catalog exists
/// it schedules a BGProcessingTask (network-required, download-sized) that runs the normal
/// tiered download + install, which fires the price-alerts diff through AppModel's funnel.
enum BackgroundRefresh {
    static let refreshTaskId = "ai.reyes.thetin.catalog-refresh"
    static let downloadTaskId = "ai.reyes.thetin.catalog-download"

    /// ⚠️ `register` is SKIPPED under XCTest, so submitting is too — the two have to agree.
    ///
    /// `submit` raises `NSInternalInconsistencyException` ("No launch handler registered…") when
    /// its id was never registered, and that is an **ObjC exception, which `try?` does not catch**.
    /// It killed the test host from `TheTin`'s own `scenePhase == .background` handler, and because
    /// the app backgrounds at whatever moment the run happens to reach, the corpse landed on a
    /// different innocent test each time: LensQueue, LocalCollectionRepository and
    /// WidgetSnapshotWriter one run, CollectionModel's cost-basis split the next — each of which
    /// passes on its own. Three phantom failures, never the same three.
    ///
    /// Lives here rather than beside the caller so every submitter is covered by construction;
    /// the asymmetry between a guarded `register` and an unguarded `submit` was the whole bug.
    static let isTesting = NSClassFromString("XCTestCase") != nil

    /// Must run before the app finishes launching — called from TheTin.init. Both ids are
    /// declared in BGTaskSchedulerPermittedIdentifiers (project.yml).
    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            handleRefresh(task as! BGAppRefreshTask, model: model)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: downloadTaskId, using: nil) { task in
            handleDownload(task as! BGProcessingTask, model: model)
        }
    }

    /// Submitted on every background transition and re-submitted from the handler; iOS treats
    /// duplicates as a replace, and submit failures (e.g. simulator) are non-fatal.
    static func scheduleRefresh() {
        guard !isTesting else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleDownload() {
        guard !isTesting else { return }
        let request = BGProcessingTaskRequest(identifier: downloadTaskId)
        request.requiresNetworkConnectivity = true // Wi-Fi-sized download tolerance
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask, model: AppModel) {
        scheduleRefresh() // keep the chain alive regardless of outcome
        let work = Task { @MainActor in
            if await model.hasNewerCatalog() { scheduleDownload() }
            task.setTaskCompleted(success: true)
        }
        // Cancellation is cooperative: the in-flight fetch throws, hasNewerCatalog returns
        // false, and the Task body still reaches setTaskCompleted — called exactly once.
        task.expirationHandler = { work.cancel() }
    }

    private static func handleDownload(_ task: BGProcessingTask, model: AppModel) {
        let work = Task { @MainActor in
            let ok = await model.backgroundCatalogUpdate()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }
}
