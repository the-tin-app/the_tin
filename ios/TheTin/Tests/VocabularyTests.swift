import XCTest

/// ⚠️ **The row and the screen it opens must agree.** `CollectionView` pinned a row titled
/// "Wanted" whose destination titled itself "Wishlist" — or "Hunting", or nothing, depending on
/// a segment choice persisted in `@AppStorage("wantedScope")`. One tap, three names across
/// sessions. First-run feedback (2026-08-12) reported it as "inconsistently named", which it was.
///
/// Same shape as `ContrastTests.testNoBareStatusColorReachesTextAgain`, for the same reason: a
/// one-time rename stops nothing, and the grep is what stops the next one.
///
/// Scans string LITERALS only. `WantedRoute`, `WantedView`, `WantedCardsView`, `WantsModel` and
/// the `wantedScope` storage key are identifiers and deliberately keep their names — renaming
/// `wantedScope` would silently reset every existing user's saved segment.
///
/// Comment lines are skipped: this codebase documents its own history heavily, and a comment
/// explaining what "Wanted" used to be is not a defect.
///
/// Deliberate exceptions carry `// vocab-ok:` on the same line.
final class VocabularyTests: XCTestCase {
    func testNoUserFacingWantedLabelSurvives() throws {
        let sources = URL(fileURLWithPath: #filePath)   // …/TheTin/Tests/VocabularyTests.swift
            .deletingLastPathComponent()                // …/TheTin/Tests
            .deletingLastPathComponent()                // …/TheTin
            .appendingPathComponent("Sources/UI")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        // A layout change that moves this file would otherwise turn the test into a silent pass
        // over zero files — the exact failure mode it exists to prevent.
        XCTAssertGreaterThan(files.count, 50, "scanned \(files.count) files — path is wrong")

        var offences: [String] = []
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard !line.contains("vocab-ok:") else { continue }
                // Odd-indexed components of a split on `"` are the string literals.
                let literals = line.split(separator: "\"", omittingEmptySubsequences: false)
                    .enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                for literal in literals where literal.contains("Wanted") {
                    offences.append("\(file.lastPathComponent):\(n + 1) — “\(literal)”")
                }
            }
        }
        XCTAssertEqual(offences, [], "user-facing “Wanted” survives — the row and its screen "
                       + "must agree:\n" + offences.joined(separator: "\n"))
    }
}
