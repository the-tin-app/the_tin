import Foundation
import UIKit

/// Your own photographs of the copies you own, on disk.
///
/// One directory per entry: `Application Support/CardPhotos/<entryId>/<uuid>.jpg`. `EntryPhotos`
/// persists FILENAMES, not paths, so relocating the container never invalidates a reference.
///
/// There is deliberately NO per-entry delete. `prune(keeping:)` at launch removes every directory
/// whose entry is gone, which covers entry deletion, a cancelled form, a CSV "Replace collection"
/// and a restore in one mechanism — instead of four call sites that each have to remember.
/// ponytail: orphans therefore live until the next launch. Cheap and invisible; add an eager
/// delete only if photo volume ever makes that matter.
struct PhotoStore: Sendable {
    /// Longest side of a saved photo, in pixels. A 48 MP original is ~12 MB and buys nothing at
    /// 126 pt in a PDF; this lands around 250 KB — which is also what gets mirrored to the
    /// user's own iCloud quota.
    static let maxDimension: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    let root: URL
    /// iCloud mirror target. nil = local only.
    var mirror: BackupStore? = nil

    static func `default`(mirror: BackupStore? = nil) -> PhotoStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PhotoStore(root: base.appendingPathComponent("CardPhotos", isDirectory: true),
                          mirror: mirror)
    }

    func directory(for entryId: String) -> URL {
        root.appendingPathComponent(entryId, isDirectory: true)
    }

    func url(entryId: String, file: String) -> URL {
        directory(for: entryId).appendingPathComponent(file)
    }

    /// Downscale, encode, write. Returns the FILENAME to store on the entry.
    func save(_ image: UIImage, entryId: String) throws -> String {
        let dir = directory(for: entryId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = Self.downscaled(image).jpegData(compressionQuality: Self.jpegQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    func image(entryId: String, file: String) -> UIImage? {
        UIImage(contentsOfFile: url(entryId: entryId, file: file).path)
    }

    /// Remove every directory whose entry id is gone. Best-effort: a failed delete leaves a stale
    /// directory, which costs disk and nothing else.
    func prune(keeping entryIds: Set<String>) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for dir in dirs where !entryIds.contains(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
    }

    /// Longest side clamped to `maxDimension`, aspect preserved, at scale 1.
    ///
    /// ⚠️ `format.scale = 1` is load-bearing. `UIGraphicsImageRendererFormat.default()` inherits
    /// the SCREEN scale, so on a 3× device the "1600 pt" render would be a 4800 px bitmap and the
    /// downscale would silently do nothing.
    static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let ratio = maxDimension / longest
        let size = CGSize(width: (image.size.width * ratio).rounded(),
                          height: (image.size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The production store: local disk plus the user's own iCloud container.
    static func live() -> PhotoStore { .default(mirror: ICloudBackupStore()) }

    // MARK: iCloud mirror
    //
    // Photos ride the BackupStore seam rather than BackupSnapshot: the snapshot is one JSON
    // rewritten on a 5 s debounce, and base64 photos in it would push megabytes on every
    // quantity edit. Every call here is best-effort and never surfaces an error — the same rule
    // BackupService follows for all iCloud failure.
    //
    // ⚠️ Both are blocking file IO. Call them off the main thread.

    /// Copy one photo up to `<container>/photos/<entryId>/<file>`.
    func mirrorUp(entryId: String, file: String) {
        guard let mirror, let container = mirror.containerURL(),
              let data = try? Data(contentsOf: url(entryId: entryId, file: file)) else { return }
        try? mirror.write(data, to: container
            .appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(entryId, isDirectory: true)
            .appendingPathComponent(file))
    }

    /// Pull every mirrored photo down. Files that already exist locally are left ALONE, so this
    /// is safe to re-run and can never overwrite a newer local capture.
    ///
    /// `requestDownload` then a coordinated `read` is the same not-yet-local materialisation
    /// dance `BackupService.loadBackup` does.
    func mirrorDown() {
        guard let mirror, let container = mirror.containerURL() else { return }
        let fm = FileManager.default
        let remoteRoot = container.appendingPathComponent("photos", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: remoteRoot, includingPropertiesForKeys: nil)
        else { return }
        for remoteDir in dirs {
            let entryId = remoteDir.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(at: remoteDir,
                                                          includingPropertiesForKeys: nil)
            else { continue }
            for remoteFile in files {
                let dest = url(entryId: entryId, file: remoteFile.lastPathComponent)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                mirror.requestDownload(remoteFile)
                guard let data = try? mirror.read(remoteFile) else { continue }
                try? fm.createDirectory(at: directory(for: entryId), withIntermediateDirectories: true)
                try? data.write(to: dest, options: .atomic)
            }
        }
    }
}
