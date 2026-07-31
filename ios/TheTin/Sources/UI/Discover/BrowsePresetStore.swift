import Foundation
import Observation

/// Named Browse filter presets, persisted as JSON in `UserDefaults`. User data — deliberately NOT
/// in the catalog DB, which is rebuilt/replaced by the nightly and would wipe it.
@MainActor @Observable
final class BrowsePresetStore {
    struct Preset: Codable, Identifiable, Hashable {
        var id: UUID = UUID()
        var name: String
        var criteria: BrowseCriteria
    }

    private(set) var presets: [Preset] = []
    private let key = "browse.presets.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        }
    }

    func save(name: String, criteria: BrowseCriteria) {
        presets.append(Preset(name: name, criteria: criteria))
        persist()
    }

    func remove(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(presets), forKey: key)
    }
}
