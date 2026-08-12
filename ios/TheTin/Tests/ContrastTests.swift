import XCTest
import SwiftUI
import UIKit
@testable import TheTin

/// Contrast floors for the colors that carry meaning in small text.
///
/// These exist because the app shipped `.green`, `.red` and `.orange` as caption-size text in a
/// dozen places, where they measure 2.22:1, 3.55:1 and 2.20:1 on a light background — and because
/// `EnergyChip` drew white letters on `.yellow` at **1.51:1**, which is very nearly invisible.
/// Neither was caught by anything: contrast is not a compile error, not a runtime warning, and not
/// visible to anyone whose eyes and screen happen to cope.
///
/// So the ratio gets asserted. The failure mode being guarded is somebody "simplifying"
/// `Color.statusPositive` back to `.green` — which looks like a cleanup and is a regression.
final class ContrastTests: XCTestCase {

    /// WCAG 2.1 AA for text below 18 pt. Every color in this file is used at caption or caption2.
    private let smallTextFloor = 4.5

    // MARK: - Ratio, straight from the WCAG definition

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func ratio(_ a: UIColor, _ b: UIColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Resolves a SwiftUI `Color` in one appearance. The status colors are dynamic — the whole
    /// point is that they differ between light and dark — so a resolution that ignores the trait
    /// collection would silently test only one of the two values.
    private func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// The two surfaces every one of these labels actually sits on: plain and grouped.
    private func backgrounds(_ style: UIUserInterfaceStyle) -> [(String, UIColor)] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        return [("systemBackground", UIColor.systemBackground.resolvedColor(with: traits)),
                ("secondarySystemBackground",
                 UIColor.secondarySystemBackground.resolvedColor(with: traits))]
    }

    // MARK: - The status colors

    func testStatusColorsClearTheSmallTextFloorInBothAppearances() {
        let cases: [(String, Color)] = [("statusPositive", .statusPositive),
                                        ("statusNegative", .statusNegative),
                                        ("statusCaution", .statusCaution),
                                        ("statusWishlist", .statusWishlist)]
        for (name, color) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for (bgName, bg) in backgrounds(style) {
                    let r = ratio(resolved(color, style), bg)
                    XCTAssertGreaterThanOrEqual(
                        r, smallTextFloor,
                        "\(name) on \(bgName) in \(style == .light ? "light" : "dark") is \(r)")
                }
            }
        }
    }

    /// The regression this file was written for. If these ever pass, someone has put the raw
    /// system colors back into small text and the assertion above is guarding nothing.
    func testTheRawSystemColorsThisReplacedWouldStillFail() {
        let light = backgrounds(.light)[0].1
        for (name, color) in [("green", Color.green), ("red", .red), ("orange", .orange)] {
            XCTAssertLessThan(ratio(resolved(color, .light), light), smallTextFloor,
                              "system \(name) unexpectedly passes — re-check this file's premise")
        }
    }

    // MARK: - Energy chips

    /// Every chip in the palette, not a sample: white failed on nine of eleven, and the two it
    /// passed on were the accident that made the bug survivable.
    func testEveryEnergyChipCarriesLegibleLetters() {
        let types = ["Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting",
                     "Darkness", "Metal", "Dragon", "Colorless", "Fairy"]
        for type in types {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let text = resolved(EnergyChip.textColor(type), style)
                let fill = resolved(EnergyChip.color(type), style)
                let r = ratio(text, fill)
                XCTAssertGreaterThanOrEqual(
                    r, smallTextFloor,
                    "\(type) letters on their own capsule are \(r) in \(style == .light ? "light" : "dark")")
            }
        }
    }

    // MARK: - The call sites

    /// ⚠️ **The test above guards the TOKEN. This one guards the CALL SITES, and it exists because
    /// the token alone stopped nothing.** `StatusColor.swift` and its assertions shipped in the
    /// same week as five surviving bare `.green`s — including both delta figures on Movers, which
    /// are the entire content of that screen. A sweep is a one-time act; nothing prevented the
    /// *next* `.green` from being typed, and an audit found them by grep in under a minute.
    ///
    /// So the grep is the test. Scope is deliberately narrow — `foregroundStyle` / `foregroundColor`
    /// only, which is where text colour lives and where every one of the failures actually was:
    ///
    /// - **`.tint(.red)` is NOT scanned.** A destructive swipe action is white-on-red and correct;
    ///   a `.bordered` button's tint is coloured text on near-white and is not. A grep cannot tell
    ///   those two apart, and a test that guesses would be dismissed the first time it cried wolf.
    ///   `SetDetailView`'s collect button was the real one and is fixed by hand.
    /// - **`UI/Print/` is excluded wholesale** — fixed-canvas PDF pages that draw black on white,
    ///   exempt from the Dynamic Type rule for the same reason.
    ///
    /// Deliberate exceptions carry `// contrast-ok:` **on the same line**, so the reason lives at
    /// the site instead of in an allowlist here that nobody would read. `BinderView` is the real
    /// case: its camera header sits on a fixed `.black.opacity(0.55)` scrim where `.orange` is
    /// ~10:1 and a status token would make the text *worse*.
    func testNoBareStatusColorReachesTextAgain() throws {
        let sources = URL(fileURLWithPath: #filePath)   // …/TheTin/Tests/ContrastTests.swift
            .deletingLastPathComponent()                // …/TheTin/Tests
            .deletingLastPathComponent()                // …/TheTin
            .appendingPathComponent("Sources/UI")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/UI/Print/") } ?? []

        // A layout change that moves this file would otherwise turn the whole test into a silent
        // pass over zero files — the exact failure mode it was written to prevent.
        XCTAssertGreaterThan(files.count, 50, "scanned \(files.count) files — path is wrong")

        let banned = [".green", ".red", ".orange", ".pink", ".yellow"]
        var offences: [String] = []
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("foregroundStyle(") || line.contains("foregroundColor(") else { continue }
                guard !line.contains("contrast-ok:") else { continue }
                for color in banned where line.contains(color) && !line.contains("Color\(color)") {
                    offences.append("\(file.lastPathComponent):\(n + 1) — bare \(color)")
                }
            }
        }
        XCTAssertEqual(offences, [], "bare system colors on text:\n" + offences.joined(separator: "\n"))
    }

    /// An unknown type still has to be readable — `EnergyChip.color` falls back to grey and the
    /// code falls back to the first two letters, so the text color has to cover that path too.
    func testAnUnknownEnergyTypeIsStillLegible() {
        let r = ratio(resolved(EnergyChip.textColor("Nucleon"), .light),
                      resolved(EnergyChip.color("Nucleon"), .light))
        XCTAssertGreaterThanOrEqual(r, smallTextFloor, "fallback chip is \(r)")
        XCTAssertEqual(EnergyChip.code("Nucleon"), "NU")
    }
}
