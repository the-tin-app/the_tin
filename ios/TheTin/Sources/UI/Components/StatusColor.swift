import SwiftUI
import UIKit

/// Contrast-safe status colors for SMALL TEXT.
///
/// ⚠️ **`.green`, `.red` and `.orange` are not usable as caption-size text on a light background,
/// and the app shipped them that way in a dozen places.** Measured against `systemBackground`
/// (white) and `secondarySystemBackground` (#F2F2F7), which is what every one of those call sites
/// actually sits on:
///
/// | | on white | on grouped |
/// |---|---|---|
/// | `.green` (#34C759) | **2.22:1** | **1.99:1** |
/// | `.red` (#FF3B30) | **3.55:1** | **3.18:1** |
/// | `.orange` (#FF9500) | **2.20:1** | **1.97:1** |
///
/// WCAG AA wants 4.5:1 for text under 18 pt. These carry real meaning — an at-target price, an
/// uncounted card in a trade, a grade estimated rather than sold — so a reader who can't resolve
/// them loses the information, not just the emphasis.
///
/// The values below clear 4.5:1 against BOTH backgrounds in BOTH appearances:
///
/// | | light | on white | on grouped | dark | on black | on #1C1C1E |
/// |---|---|---|---|---|---|---|
/// | positive | #1D7A35 | 5.40 | 4.84 | #30D158 | 10.39 | 8.42 |
/// | negative | #D70015 | 5.38 | 4.83 | #FF453A | 6.16 | 4.99 |
/// | caution | #A85400 | 5.34 | 4.78 | #FF9F0A | 10.22 | 8.28 |
///
/// The dark-appearance values ARE the system colors — `systemGreen`/`systemRed`/`systemOrange`
/// already pass on a dark background. Only the light side needed darkening, which is why this is
/// a dynamic `UIColor` and not three flat constants: hard-coding the light value would wreck the
/// dark appearance that was never broken.
///
/// ⚠️ **These resolve by APPEARANCE, not by the color behind them.** Text over a fixed dark scrim
/// — `BinderView`'s camera header sits on `.black.opacity(0.55)` — must keep using the bright
/// system colors, where `.yellow` measures ~13:1 and `.orange` ~10:1. Reaching for a token here
/// would make that text *worse*. Appearance-adaptive tokens are for text on app chrome.
///
/// ⚠️ Color is never the only channel at any of these call sites, and must not become one:
/// `DeltaBadge` pairs the tint with a direction arrow and a spoken label, and the rest sit beside
/// words that say the same thing. This fixes legibility, not meaning.
extension Color {
    /// Gains, completions, targets met. Replaces a bare `.green` on text.
    static let statusPositive = Color(uiColor: .init { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)   // #30D158
        : UIColor(red: 0.114, green: 0.478, blue: 0.208, alpha: 1) }) // #1D7A35

    /// Losses and failures. Replaces a bare `.red` on text.
    static let statusNegative = Color(uiColor: .init { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1)   // #FF453A
        : UIColor(red: 0.843, green: 0.000, blue: 0.082, alpha: 1) }) // #D70015

    /// "We don't know this" and "this is an estimate" — never an error. Replaces a bare `.orange`.
    static let statusCaution = Color(uiColor: .init { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1)   // #FF9F0A
        : UIColor(red: 0.659, green: 0.329, blue: 0.000, alpha: 1) }) // #A85400
}
