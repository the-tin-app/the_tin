import Foundation
import os

/// Per-stage wall-clock timing for the live scan pipeline. Emits os_signpost intervals
/// (subsystem ai.reyes.thetin / category scan — visible in Instruments' "Points of Interest"
/// style signpost lanes) and accumulates a per-frame breakdown for a one-line log.
struct StageTimer {
    private static let signposter = OSSignposter(subsystem: "ai.reyes.thetin", category: "scan")
    private(set) var stages: [(name: String, ms: Double)] = []

    mutating func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = Self.signposter.beginInterval(name)
        let t0 = ContinuousClock.now
        defer {
            Self.signposter.endInterval(name, state)
            let d = ContinuousClock.now - t0
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            stages.append((String(describing: name), ms))
        }
        return try body()
    }

    var summary: String {
        stages.map { "\($0.name)=\(String(format: "%.0f", $0.ms))ms" }.joined(separator: " ")
    }
}
