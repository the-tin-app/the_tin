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
    /// The lexicon, as the only thing that can actually enforce one: banned spelling → what to say
    /// instead. Documented for humans in DESIGN.md §6.
    ///
    /// Every entry here is a name that once shipped and was replaced. "Wanted" is the original
    /// (#159). "Want List" was found later in the same sweep, still titling the printed wishlist
    /// PDF months after the door itself had been renamed — which is the point: renaming a screen
    /// does not rename the eleven other places that quote it, and only a test notices.
    ///
    /// ⚠️ **`caseSensitive` is load-bearing, and matching everything loosely is wrong.** The
    /// literal splitter below is a `split(on: "\"")`, so it cannot tell a string from the *code
    /// inside an interpolation*. Lowercase `wanted` is a perfectly good local variable — `LensMatcher`
    /// logs `wanted=\(wanted.count)`, `MoversView` builds an accessibility label from `wanted ? …`,
    /// and `WantedView` stores its segment under the `wantedScope` key it must never rename.
    /// Matching "Wanted" case-insensitively flagged all three. Capitalised is how the retired word
    /// appeared in copy; the lowercase forms that matter are phrases, and a phrase can't collide
    /// with an identifier.
    static let banned: [(term: String, instead: String, caseSensitive: Bool)] = [
        ("Wanted", "Wishlist — the pinned row and the screen it opens must agree", true),
        ("wanted list", "Wishlist — e.g. “On your wishlist”", false),
        ("Want List", "Wishlist", false),
        ("Wantlist", "Wishlist", false),
    ]

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
                for literal in literals {
                    for entry in Self.banned {
                        let options: String.CompareOptions = entry.caseSensitive ? [] : [.caseInsensitive]
                        guard literal.range(of: entry.term, options: options) != nil else { continue }
                        offences.append("\(file.lastPathComponent):\(n + 1) — “\(literal)” "
                                        + "(say: \(entry.instead))")
                    }
                }
            }
        }
        XCTAssertEqual(offences, [], "a retired name survives in user-facing copy — every concept "
                       + "gets ONE spelling (DESIGN.md §6):\n" + offences.joined(separator: "\n"))
    }
}
