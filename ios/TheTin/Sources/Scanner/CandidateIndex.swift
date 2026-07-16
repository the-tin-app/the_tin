import Foundation

/// Narrows an OCR-plate read to a ranked candidate pool and scores per-candidate OCR/twin
/// agreement, feeding `ScanSession`'s F1 lock gate. `CandidateIndex` is the production
/// conformance; tests inject a deterministic stub
/// since the fingerprint fixture ids aren't real catalog cards and can't be OCR-narrowed.
protocol CandidateNarrowing {
    func pool(fields: OcrFields) -> [String]
    func consistency(cardId: String, fields: OcrFields, pool: Set<String>) -> CandidateConsistency
}

final class CandidateIndex: CandidateNarrowing {
    private var byNumberTotal: [String: [String]] = [:]   // "normalizedNumber/total" -> [cardId]
    private var byNumber: [String: [String]] = [:]        // "normalizedNumber" -> [cardId]
    // RAW catalog number (never Int-collapsed) + hp + basename + setId, keyed by card id —
    // feeds pool()'s number/hp signals (raw number avoids the promo regression: a shared "-1"
    // bucket would let one promo's number match every other promo's card) and consistency()'s
    // name/denominator checks.
    private var byId: [String: (name: String, number: String, hp: Int?, basename: String, setId: String)] = [:]
    // printed_total per set, cached at init (store.printedTotal is a per-call DB hit) — twins()
    // stays live since card_twin lookups are already cheap single-row reads.
    private var printedTotalBySet: [String: Int] = [:]
    private let store: CatalogStore

    init(store: CatalogStore) throws {
        self.store = store
        for set in try store.sets() {
            let total = set.total                        // catalog set total
            printedTotalBySet[set.id] = try store.printedTotal(setId: set.id)
            for c in try store.cards(inSet: set.id) {
                // Numeric catalog numbers normalize (strip leading zeros) to match OCR's
                // leading-zero-stripped query numbers; non-numeric (promo) numbers keep their
                // raw form instead of collapsing to a shared "-1" bucket.
                let normalized = Int(c.number).map(String.init) ?? c.number
                byNumberTotal["\(normalized)/\(total)", default: []].append(c.id)
                byNumber[normalized, default: []].append(c.id)
                byId[c.id] = (c.name.lowercased(), c.number, c.hp, Self.baseName(c.name), set.id)
            }
        }
    }

    func candidates(number: String?, total: Int?, name: String?) -> [String] {
        guard let number else { return [] }
        let lname = name?.lowercased()

        // 1. Exact number+total — near-unique when the printed denominator matches the catalog total.
        var ids: [String] = []
        if let total { ids = byNumberTotal["\(number)/\(total)"] ?? [] }

        // 2. Fallback: the PRINTED total frequently differs from the catalog total (EX-era secret
        //    rares inflate it — e.g. printed "58/112" vs catalog total 116). When number+total
        //    misses, gate on number + name instead. Require a name so the set stays small.
        if ids.isEmpty, let lname, !lname.isEmpty {
            ids = (byNumber[number] ?? []).filter { nameMatches($0, lname) }
        }

        // 3. Narrow a cross-set number+total hit by name when we have one.
        if ids.count > 1, let lname, !lname.isEmpty {
            let narrowed = ids.filter { nameMatches($0, lname) }
            if !narrowed.isEmpty { ids = narrowed }
        }
        return ids
    }

    private func nameMatches(_ cardId: String, _ lname: String) -> Bool {
        let cardName = byId[cardId]?.name ?? ""
        return cardName.contains(lname) || lname.contains(cardName)
    }

    // MARK: - E2 soft-narrow pool

    /// Ranked pool of candidate card ids for the visual matcher to confirm. Soft-narrow: a card
    /// matching EITHER the text pass (name/attack-name via FTS) OR the number pass is a
    /// candidate — nothing is hard-excluded here (F1 does the strict lock checks). Ranked by
    /// field agreement (text match + number match + hp match), capped at 160.
    /// Ported from `fingerprint/eval/scorer.py`'s proven pool block, extended with FTS-backed
    /// attack-name narrowing (Plan 1 indexed attack names into `card_text.body`).
    func pool(fields: OcrFields) -> [String] {
        let tokens = significantTokens(fields.rawText)
        let textIds = Set((try? store.cardIdsMatchingText(tokens: tokens)) ?? [])

        var numberMatchIds = Set<String>()
        for (id, info) in byId where matchesNumber(info.number, fields.numerators) {
            numberMatchIds.insert(id)
        }

        let poolIds = textIds.union(numberMatchIds)
        guard !poolIds.isEmpty else { return [] }

        let scored: [(id: String, agreement: Int)] = poolIds.map { id in
            let textMatch = textIds.contains(id)
            let numberMatch = numberMatchIds.contains(id)
            let hpMatch = fields.hp != nil && byId[id]?.hp == fields.hp
            let agreement = (textMatch ? 1 : 0) + (numberMatch ? 1 : 0) + (hpMatch ? 1 : 0)
            return (id, agreement)
        }

        // Sort by agreement DESC; break ties by id for a deterministic pool (both passes draw
        // from Sets, which have no inherent order).
        return scored
            .sorted { $0.agreement != $1.agreement ? $0.agreement > $1.agreement : $0.id < $1.id }
            .prefix(160)
            .map(\.id)
    }

    /// Lowercased alphanumeric words of length >= 3, for the FTS text pass.
    private func significantTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    /// Mirrors scorer.py's `cn in numerators or cn.upper() in numerators or cn.lstrip('0') in
    /// numerators` — `cn` is the RAW catalog number string.
    private func matchesNumber(_ cn: String, _ numerators: [String]) -> Bool {
        guard !numerators.isEmpty else { return false }
        if numerators.contains(cn) { return true }
        if numerators.contains(cn.uppercased()) { return true }
        return numerators.contains(String(cn.drop { $0 == "0" }))
    }

    // MARK: - F1 consistency (name/denominator/twin agreement for the visual winner)

    /// Per-candidate OCR/twin agreement for `ScanSession`'s lock gate. `cardId` is the visual
    /// (RANSAC) winner; `fields` is this frame's full-plate OCR read; `pool` is the narrowing
    /// pool the winner was confirmed against.
    func consistency(cardId: String, fields: OcrFields, pool: Set<String>) -> CandidateConsistency {
        guard let info = byId[cardId] else {
            return CandidateConsistency(nameAgrees: false, denomOk: fields.denominator == nil, hasTwinInPool: false)
        }
        let nameAgrees = info.basename.count >= 3 && fields.rawText.lowercased().contains(info.basename)
        let denomOk: Bool
        if let denominator = fields.denominator {
            denomOk = printedTotalBySet[info.setId] == Int(denominator)
        } else {
            denomOk = true
        }
        let twins = (try? store.twins(cardId: cardId)) ?? []
        let hasTwinInPool = !twins.isDisjoint(with: pool)
        return CandidateConsistency(nameAgrees: nameAgrees, denomOk: denomOk, hasTwinInPool: hasTwinInPool)
    }

    /// Ports `scorer.py`'s `base_name(n)`: lowercase, strip stage/mechanic suffixes and
    /// "mega "/apostrophes, so OCR text (which never prints "EX"/"VMAX" as part of the base
    /// species name search) can still substring-match the card's core name.
    private static func baseName(_ name: String) -> String {
        var n = name.lowercased()
        for suffix in [" ex", " vmax", " vstar", " v", " lv.x"] {
            n = n.replacingOccurrences(of: suffix, with: "")
        }
        n = n.replacingOccurrences(of: "mega ", with: "").replacingOccurrences(of: "'", with: "")
        return n.trimmingCharacters(in: .whitespaces)
    }
}
