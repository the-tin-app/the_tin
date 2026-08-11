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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Compact

    private var compactBody: some View {
        VStack(spacing: 2) {
            Text(card.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(2).multilineTextAlignment(.center)
            if let hp = card.hp {
                Text("HP \(hp)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(numberLine).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
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
                    Text("No image offline").font(.system(size: 9))
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
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                        Text(ability.name).font(.caption.bold()).lineLimit(1)
                    }
                    if let effect = ability.effect {
                        Text(effect).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
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
                        Text(effect).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            // Trainers print their rules where a Pokémon prints attacks.
            if let effect = detail?.effect, card.attacks.isEmpty {
                Text(effect).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(6)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let combat = combatLine {
                Text(combat).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(numberLine).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 2)
                if let mark = detail?.regulationMark {
                    Text(mark).font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.quaternary))
                }
            }
            let credits = [card.rarity, card.artist.map { "illus. \($0)" }].compactMap { $0 }
            if !credits.isEmpty {
                Text(credits.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
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
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Capsule().fill(Self.color(type)))
            .accessibilityLabel(type)
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

    private static let colors: [String: Color] = [
        "grass": .green, "fire": .red, "water": .blue, "lightning": .yellow,
        "psychic": .purple, "fighting": .orange, "darkness": .black, "metal": .gray,
        "dragon": .brown, "colorless": .secondary, "fairy": .pink,
    ]
}
