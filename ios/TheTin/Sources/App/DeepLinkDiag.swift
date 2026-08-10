import Foundation

/// A breadcrumb trail for inbound universal links, readable off a device without a debugger.
///
/// `log stream` cannot attach to a device on this macOS, but
/// `devicectl device copy from … Library/Preferences/ai.reyes.thetin.plist` can — so UserDefaults
/// is the one instrument that reaches a real device here (CLAUDE.md, "Reading a device's
/// UserDefaults"). This exists because scanning a printed label with the system Camera opens the
/// app but does not navigate, identically cold and warm, and two reasoned hypotheses were both
/// wrong. Reasoning has had its turn.
///
/// DEBUG-only in every respect: the calls compile to nothing in Release, so no shipped build
/// writes any of this.
enum DeepLinkDiag {
    static let key = "diagDeepLinkTrail"

    /// Appends `step: detail` with a timestamp, keeping the last few entries. Ordered oldest
    /// first, so the trail reads top to bottom.
    static func record(_ step: String, _ detail: String) {
        #if DEBUG
        Diag.append(key: key, "\(step): \(detail)", keeping: 12)
        #endif
    }
}

/// The same instrument pointed at the entry form's photo tiles — it lives here rather than in its
/// own file so that adding it needed no `xcodegen` round trip.
///
/// Two guesses at "I picked a photo and nothing happened" have now been wrong. The trail records
/// every step from the tap to the file landing on the entry, including `populate` — the one that
/// silently *undoes* the others.
enum PhotoDiag {
    static let key = "diagPhotoTrail"

    static func record(_ step: String, _ detail: String = "") {
        #if DEBUG
        Diag.append(key: key, detail.isEmpty ? step : "\(step): \(detail)", keeping: 30)
        #endif
    }
}

private enum Diag {
    static func append(key: String, _ line: String, keeping: Int) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var trail = UserDefaults.standard.stringArray(forKey: key) ?? []
        trail.append("\(stamp) \(line)")
        UserDefaults.standard.set(Array(trail.suffix(keeping)), forKey: key)
    }
}
