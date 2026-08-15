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
    /// ⚠️ **Two mechanisms guard this list, and they cover different failures. Neither is
    /// redundant.** Both exist because the splitter below is a `split(on: "\"")`, which cannot tell
    /// copy from an identifier that happens to be spelled the same way.
    ///
    /// 1. `withoutInterpolations` drops `\(…)` spans, killing the *structural* half: the code
    ///    inside an interpolation is not copy. `"installed v\(v)\(tier)"` is a log line, not the
    ///    catalog being called a tier, and `MoversView`'s accessibility label built from
    ///    `\(wanted ? …)` is not the retired word. Without this the term list cannot grow past a
    ///    handful of phrases, because every term has to be spelled so as to dodge its own codebase.
    /// 2. `caseSensitive` covers what stripping cannot: identifiers that are *whole literals* or
    ///    literal text outside any interpolation. `LensMatcher` logs `"cells=\(cells.count)
    ///    wanted=\(wanted.count)"` — the `wanted=` is real literal text and survives stripping —
    ///    and `WantedView` persists `@AppStorage("wantedScope")`, a bare literal it must never
    ///    rename, because renaming it silently resets every existing user's saved segment.
    ///
    /// So: capitalised is how the retired word appeared in copy, and the lowercase forms that
    /// matter are phrases, because a phrase can't collide with an identifier. Do not delete the
    /// flag on the grounds that stripping now exists — it would re-flag both cases above.
    static let banned: [(term: String, instead: String, caseSensitive: Bool)] = [
        ("Wanted", "Wishlist — the pinned row and the screen it opens must agree", true),
        ("wanted list", "Wishlist — e.g. “On your wishlist”", false),
        ("Want List", "Wishlist", false),
        ("Wantlist", "Wishlist", false),
        ("tier", "size — the catalog comes in three sizes; “tier” is the type name, not user copy", false),
        ("set goals", "Sets — the Wishlist segment", false),
        ("your collection", "your tin", false),
        ("the collection", "the tin", false),
    ]

    func testNoUserFacingWantedLabelSurvives() throws {
        let theTin = URL(fileURLWithPath: #filePath)    // …/TheTin/Tests/VocabularyTests.swift
            .deletingLastPathComponent()                // …/TheTin/Tests
            .deletingLastPathComponent()                // …/TheTin
        // All of Sources, not just UI: `ShareList.Kind.title` sat in Sources/Collection returning
        // "Want List" for months after #159 retired the name, with no call sites at all — outside
        // the old Sources/UI scan the whole time. The widget is a separate target and ships its
        // own copy; it called the tin "your collection" while its own display name said "Tin value".
        let roots = [theTin.appendingPathComponent("Sources"),
                     theTin.deletingLastPathComponent()          // …/ios
                         .appendingPathComponent("TheTinWidgets/Sources")]
        let files = roots.flatMap { root in
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }

        // A layout change that moves this file would otherwise turn the test into a silent pass
        // over zero files — the exact failure mode it exists to prevent.
        XCTAssertGreaterThan(files.count, 150, "scanned \(files.count) files — path is wrong")

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
                for literal in literals.map(Self.withoutInterpolations) {
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

    /// Drops `\(…)` spans, because the splitter above cannot tell copy from the *code inside an
    /// interpolation* — and the code is where the identifiers live. `"installed v\(v)\(tier)"` is a
    /// log line, not a user calling the catalog a tier; `"Deleted “\(group.name)”"` is not the word
    /// "group" in copy. Without this, every term below has to be spelled as a phrase to dodge its
    /// own codebase, which is how the term list stays too small to catch anything.
    ///
    /// Nesting is counted, so `\(a ? "x" : "y")` drops whole. The splitter has already cut on `"`,
    /// so a nested literal arrives as its own component and is scanned on its own anyway.
    static func withoutInterpolations(_ literal: Substring) -> String {
        var out = ""
        var depth = 0
        var i = literal.startIndex
        while i < literal.endIndex {
            let next = literal.index(after: i)
            if depth == 0, literal[i] == "\\", next < literal.endIndex, literal[next] == "(" {
                depth = 1
                i = literal.index(after: next)
                continue
            }
            if depth > 0 {
                if literal[i] == "(" { depth += 1 } else if literal[i] == ")" { depth -= 1 }
            } else {
                out.append(literal[i])
            }
            i = next
        }
        return out
    }
}
