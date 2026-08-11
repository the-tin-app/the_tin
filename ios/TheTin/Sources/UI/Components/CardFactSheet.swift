import SwiftUI

/// The card, rendered from catalog data, with the art window deliberately blank.
///
/// This is what you get when there is no artwork — offline at a convention, or for the ~150 cards
/// whose art is permanently 403. It exists so "is this the card the app says it is?" is answerable
/// with the physical card in your hand: the same facts the card prints, in the same reading order.
///
/// ⚠️ **This is deliberately NOT a replica of a Pokémon card frame.** No yellow border, no
/// type-coloured background band, no copied energy symbols, no HP in its printed position.
/// Trade dress is exactly what guideline 4.1(a) ("Copycats") covers, and a hand-built replica is a
/// WORSE exposure than the art ever was — cached art has the "the device fetched it, we never
/// redistribute" defence, whereas a replica frame is us manufacturing the thing the mark lives in.
/// Four review cycles have already been spent on this surface. Same *information* in the same
/// *spatial logic*, in our own typography: recognisable as a Tin fact sheet, not mistakable for a
/// scan of a card.
///
/// It is also better at the job. A replica invites "looks the same, ship it" at a glance; a
/// distinctly-ours sheet makes you read the number, which is the check you actually wanted.
struct CardFactSheet: View {
    enum Density {
        /// Grid tiles (~55–100 pt wide). Identity only — anything else is unreadable at that size.
        case compact
        /// Detail size. The whole sheet.
        case full
    }

    let card: CardRecord
    var density: Density = .full
    /// Passed in by callers that already hold the set, NEVER looked up here. A catalog read inside
    /// a grid cell's `body` re-runs per cell per render — the mistake `CardDetailModel.init`'s
    /// twelve synchronous reads and the note on `BinderRow.card` both exist to prevent. Callers
    /// without a set render "SVI #223"; callers with one render "Darkness Ablaze · #136/189".
    var setName: String?
    var setTotal: Int?

    private var detail: CardDetail? { card.detail }
    private var isTrainer: Bool { (detail?.category ?? "").caseInsensitiveCompare("Trainer") == .orderedSame }

    var body: some View {
        Group {
            switch density {
            case .compact: compactBody
            case .full:    fullBody
            }
        }
        .foregroundStyle(.primary)
        // ⚠️ Everything here used to be `.system(size: 8…10)` — frozen point sizes below the 11pt
        // HIG floor, on the one surface whose whole job is "read the number and check it against
        // the card in your hand". A collector who needs larger text got the smallest type in the
        // app precisely where reading mattered most. It is all Dynamic Type text styles now.
        //
        // The CAP is the honest part. This sheet is a card — a fixed 0.717 aspect ratio, sized by
        // its container — so past a point the type cannot grow without the facts falling out of
        // the frame, and `minimumScaleFactor` would just shrink them back down anyway. `.compact`
        // is a ~55–100pt grid tile and stops early; `.full` is the detail sheet and has room to
        // reach the first accessibility size. Beyond the cap the combined `accessibilityLabel`
        // below is the real answer, and it carries the same facts at any size.
        .dynamicTypeSize(density == .compact ? ...DynamicTypeSize.xLarge
                                             : ...DynamicTypeSize.accessibility1)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Compact

    private var compactBody: some View {
        VStack(spacing: 2) {
            Text(card.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2).multilineTextAlignment(.center)
            if let hp = card.hp {
                Text("HP \(hp)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(numberLine).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .minimumScaleFactor(0.6)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Full

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // The art window is the ONLY flexible row: when a card has a lot of rules text the
            // window collapses and the text stays legible, rather than the text being clipped to
            // preserve a blank rectangle.
            artWindow.frame(maxHeight: .infinity)
            if let line = evolutionLine {
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            rules
            Spacer(minLength: 0)
            footer
        }
        .minimumScaleFactor(0.6)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.name).font(.subheadline.bold()).lineLimit(2)
                Spacer(minLength: 2)
                if let hp = card.hp {
                    Text("HP \(hp)").font(.caption.bold()).monospacedDigit().layoutPriority(1)
                }
            }
            if !card.types.isEmpty {
                HStack(spacing: 3) { ForEach(card.types, id: \.self) { EnergyChip(type: $0) } }
            }
        }
    }

    /// Says "we do not have the picture" instead of pretending. Dashed, so it reads as an absence
    /// rather than as a panel that failed to fill.
    private var artWindow: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.quaternary)
            .frame(minHeight: 26)
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "photo").font(.caption)
                    Text("No image offline").font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            }
    }

    var evolutionLine: String? {
        guard let d = detail else { return nil }
        if isTrainer { return d.trainerType.map { "Trainer · \($0)" } }
        let stage = d.stage.map(Self.humanStage)
        switch (stage, d.evolveFrom) {
        case let (s?, from?): return "\(s) · evolves from \(from)"
        case let (s?, nil):   return s
        case let (nil, from?): return "Evolves from \(from)"
        default: return nil
        }
    }

    /// "Stage1" → "Stage 1". The API packs the digit against the word.
    static func humanStage(_ raw: String) -> String {
        guard let i = raw.firstIndex(where: \.isNumber), i != raw.startIndex else { return raw }
        return "\(raw[raw.startIndex..<i]) \(raw[i...])"
    }

    @ViewBuilder private var rules: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array((detail?.abilities ?? []).enumerated()), id: \.offset) { _, ability in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(ability.type ?? "Ability")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                        Text(ability.name).font(.caption.bold()).lineLimit(1)
                    }
                    if let effect = ability.effect {
                        Text(effect).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            ForEach(Array(card.attacks.enumerated()), id: \.offset) { _, attack in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ForEach(Array(attack.cost.enumerated()), id: \.offset) { _, c in
                            EnergyChip(type: c)
                        }
                        Text(attack.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        if let damage = attack.damage {
                            Text(damage).font(.caption.bold()).monospacedDigit().layoutPriority(1)
                        }
                    }
                    if let effect = attack.effect {
                        Text(effect).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            // Trainers print their rules where a Pokémon prints attacks.
            if let effect = detail?.effect, card.attacks.isEmpty {
                Text(effect).font(.caption2).foregroundStyle(.secondary).lineLimit(6)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let combat = combatLine {
                Text(combat).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(numberLine).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 2)
                if let mark = detail?.regulationMark {
                    Text(mark).font(.caption2.bold())
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.quaternary))
                }
            }
            let credits = [card.rarity, card.artist.map { "illus. \($0)" }].compactMap { $0 }
            if !credits.isEmpty {
                Text(credits.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// "Weak Fighting ×2 · Resist — · Retreat 1". Omitted entirely when the card has none of it,
    /// rather than printing three em dashes that look like data we failed to load.
    var combatLine: String? {
        guard let d = detail else { return nil }
        var parts: [String] = []
        if let w = d.weaknesses?.first { parts.append("Weak \(w.type) \(w.value)") }
        if let r = d.resistances?.first { parts.append("Resist \(r.type) \(r.value)") }
        if let retreat = d.retreat { parts.append("Retreat \(retreat)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "SWSH3 #136/189" — the denominator only when a caller handed us the set.
    var numberLine: String {
        let label = setName ?? card.setId.uppercased()
        guard let total = setTotal else { return "\(label) #\(card.number)" }
        return "\(label) #\(card.number)/\(total)"
    }

    private var accessibilitySummary: String {
        var parts = [card.name]
        if let hp = card.hp { parts.append("HP \(hp)") }
        parts.append(numberLine)
        parts.append("No image available offline")
        return parts.joined(separator: ", ")
    }
}

/// One energy requirement, as a lettered capsule.
///
/// Deliberately a two-letter code and not a facsimile of the printed energy symbol — see the
/// trade-dress note on `CardFactSheet`. Two letters rather than one because Fire and Fighting
/// both start with F, and colour alone is not an accessible distinction.
struct EnergyChip: View {
    let type: String

    var body: some View {
        Text(Self.code(type))
            .font(.system(.caption2, design: .rounded).weight(.heavy))
            .foregroundStyle(Self.textColor(type))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Capsule().fill(Self.color(type)))
            .accessibilityLabel(type)
    }

    /// ⚠️ **This was `.white` on every chip, and white failed on nine of the eleven.** Measured
    /// against each capsule's own fill: `.yellow` gave **1.51:1** — the two letters were very
    /// nearly invisible — `.orange` 2.20, `.green` 2.22, `.gray` 3.26, `.pink` 3.65, `.red` 3.55,
    /// `.brown` 3.50, `.blue` 4.02, `.purple` 4.13. All under the 4.5:1 floor for text this size.
    ///
    /// Black clears it on all of them (5.08–13.89), so the rule is black everywhere except the one
    /// genuinely dark chip. The letters are the whole point of the chip — the doc note above says
    /// colour alone is not an accessible distinction, and unreadable letters put us back to
    /// exactly that.
    static func textColor(_ type: String) -> Color {
        type.lowercased() == "darkness" ? .white : .black
    }

    static func code(_ type: String) -> String {
        if let known = codes[type.lowercased()] { return known }
        return String(type.prefix(2)).uppercased()
    }

    static func color(_ type: String) -> Color {
        colors[type.lowercased()] ?? .gray
    }

    private static let codes: [String: String] = [
        "grass": "GR", "fire": "FR", "water": "WA", "lightning": "LI", "psychic": "PS",
        "fighting": "FG", "darkness": "DK", "metal": "MT", "dragon": "DR",
        "colorless": "CL", "fairy": "FY",
    ]

    /// ⚠️ Colorless is a FIXED grey, not `.secondary`. Several of these fills DO shift a little
    /// between light and dark — systemGreen is #34C759/#30D158, systemYellow #FFCC00/#FFD60A —
    /// and that is fine, because they shift within the same lightness band and black stays
    /// legible on both. `.secondary` was different in kind: it INVERTS, dark grey in light mode
    /// and light grey in dark, so no single text colour can sit on it. `ContrastTests` checks
    /// every chip in both appearances rather than trusting either claim. Lighter than metal's
    /// `.gray` (#8E8E93) so the two neutral chips stay distinguishable.
    private static let colors: [String: Color] = [
        "grass": .green, "fire": .red, "water": .blue, "lightning": .yellow,
        "psychic": .purple, "fighting": .orange, "darkness": .black, "metal": .gray,
        "dragon": .brown, "fairy": .pink,
        "colorless": Color(red: 0.72, green: 0.72, blue: 0.75),
    ]
}
