import Foundation

/// Real iCloud Drive store: resolves the app's default ubiquity container
/// (`iCloud.ai.reyes.thetin`, the entitlements' only container) and does all file IO through
/// NSFileCoordinator — required for ubiquitous files. Stateless; every method is best-effort
/// and callers run it off-main (container resolution and coordinated reads can block).
struct ICloudBackupStore: BackupStore {
    func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    func read(_ url: URL) throws -> Data {
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordError) { actual in
            do { try data.write(to: actual, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    func rotate(_ url: URL, to prev: URL) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMoving,
                                       writingItemAt: prev, options: .forReplacing,
                                       error: &coordError) { from, to in
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
