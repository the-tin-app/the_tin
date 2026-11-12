import Foundation
import Observation

/// The few moments where The Tin has just done something useful for someone, and so the only
/// places a tip is ever mentioned outside Settings. Each is a screen the person chose to open.
enum SupportMoment: String, CaseIterable {
    /// The scan tray emptied into their tin.
    case scanFiled
    /// Wishlist cards dropped in price — the app just saved them money.
    case wishlistDrop
    /// They're looking at what their tin is worth over time.
    case portfolioValue
    /// "My Cards" movers: what their own collection did.
    case myMovers

    /// One honest line that ties the ask to what they were just doing.
    var lead: String {
        switch self {
        case .scanFiled: return "Filed — that's in your tin."
        case .wishlistDrop: return "Catching price drops is what The Tin is for."
        case .portfolioValue: return "Watching your tin's value is the point of The Tin."
        case .myMovers: return "That's your tin, moving."
        }
    }
}

/// Decides whether a tip note may appear, and remembers that it did.
///
/// The rules are the product, not tuning:
/// - **At most one note a week, across every screen.** Showing a note spends the week's slot
///   whether or not anyone acts on it, so *ignoring it* is the same as asking for a quiet week —
///   there is no separate "ignored" state to track or get wrong.
/// - **Tapping ✕ is a stronger no**: a month.
/// - **A tip ends it**: no note for six months. Someone who tipped has done their part.
/// - **Only when there is something to buy.** No note while the offering hasn't loaded (offline,
///   no key), so it can never lead to a dead end.
/// - **Never on launch, never modal.** A note only ever appears in a screen's own content, via a
///   screen's `offer` call, and leaving the screen removes it.
@MainActor @Observable
final class SupportPromptModel {
    static let cooldown: TimeInterval = 7 * 86_400
    static let dismissedCooldown: TimeInterval = 30 * 86_400
    static let tippedCooldown: TimeInterval = 180 * 86_400
    private static let key = "supportPrompt.nextEligible"

    let tipJar: TipJarModel
    /// The moment whose note is on screen right now, if any.
    private(set) var current: SupportMoment?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(tipJar: TipJarModel, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.tipJar = tipJar
        self.defaults = defaults
        self.now = now
        tipJar.onThanked = { [weak self] in self?.tipped() }
    }

    private var nextEligible: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.key)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.key) }
    }

    /// A screen calls this when its delight condition holds. Cheap to call repeatedly: it only
    /// ever shows one note at a time, and only spends the week's slot the first time it shows.
    func offer(_ moment: SupportMoment) async {
        await tipJar.load()
        guard tipJar.isAvailable, current == nil else { return }
        let t = now()
        guard t >= nextEligible else { return }
        current = moment
        nextEligible = t.addingTimeInterval(Self.cooldown)
    }

    /// The screen went away. The slot stays spent — leaving is not a reason to ask again sooner.
    func leave(_ moment: SupportMoment) {
        if current == moment { current = nil }
    }

    /// ✕: a month of quiet.
    func dismiss() {
        current = nil
        nextEligible = max(nextEligible, now().addingTimeInterval(Self.dismissedCooldown))
    }

    private func tipped() {
        current = nil
        nextEligible = max(nextEligible, now().addingTimeInterval(Self.tippedCooldown))
    }
}

/// What it actually costs to run The Tin, stated plainly wherever a tip is asked for. Figures are
/// rounded and monthly; they live here once so the note and the tip screen can't disagree.
enum SupportCosts {
    struct Line { let name: String; let amount: String }

    static let lines: [Line] = [
        Line(name: "Card price data", amount: "$99 / month"),
        Line(name: "Apple Developer Program", amount: "$99 / year"),
        Line(name: "Cloudflare hosting", amount: "$5–10 / month"),
    ]
    static let totalText = "$115 / month"
}
