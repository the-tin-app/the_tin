import Foundation
import GRDB

extension CatalogStore {
    /// Offline FTS5 search per spec §5.1: name/body prefix tokens (unqualified — matches a
    /// Pokémon name OR an attack/ability name/effect, so "slash" alone finds every card with a
    /// Slash attack), optional exact body phrase, optional HP filter, optional card-number filter.
    func search(_ query: SearchQuery, limit: Int = 100) throws -> [CardRecord] {
        guard !query.isEmpty else { return [] }

        var matchParts: [String] = []
        if !query.nameTokens.isEmpty {
            // No column qualifier ⇒ FTS5 matches either indexed column, so a plain word finds a
            // Pokémon name AND an attack/ability name/effect in the same pass (card_text.body is
            // populated from attack+ability name+effect text — see flatten-cards-db.ts).
            let prefixes = query.nameTokens.map { "\(ftsQuoted($0))*" }.joined(separator: " ")
            matchParts.append("(\(prefixes))")
        }
        if let phrase = query.textPhrase {
            matchParts.append("body : \(ftsQuoted(phrase))")
        }

        var hpSQL = ""
        var hpArgs: [DatabaseValueConvertible] = []
        switch query.hp {
        case .exact(let v): hpSQL = " AND card.hp = ?"; hpArgs = [v]
        case .range(let min, let max):
            if let min { hpSQL += " AND card.hp >= ?"; hpArgs.append(min) }
            if let max { hpSQL += " AND card.hp <= ?"; hpArgs.append(max) }
        case nil: break
        }

        var numberSQL = ""
        var numberArgs: [DatabaseValueConvertible] = []
        if let number = query.number {
            numberSQL = " AND card.number = ?"
            numberArgs = [number.local]
            if let total = number.total {
                // The printed denominator lands in either `total` or `printed_total` depending on
                // era (secret rares push `total` past the printed count) — accept either.
                numberSQL += " AND card.set_id IN (SELECT id FROM set_info WHERE total = ? OR printed_total = ?)"
                numberArgs += [total, total]
            }
        }

        return try dbQueue.read { db in
            if matchParts.isEmpty {
                // HP/number-only query: plain column scan, no FTS involved.
                let sql = "SELECT * FROM card WHERE 1=1\(hpSQL)\(numberSQL) ORDER BY name LIMIT ?"
                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(hpArgs + numberArgs + [limit]))
                    .map(CatalogStore.cardRecord)
            }
            let sql = """
                SELECT card.* FROM card_text
                JOIN card ON card.id = card_text.card_id
                WHERE card_text MATCH ?\(hpSQL)\(numberSQL)
                ORDER BY bm25(card_text) LIMIT ?
                """
            let args: [DatabaseValueConvertible] = [matchParts.joined(separator: " AND ")] + hpArgs + numberArgs + [limit]
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map(CatalogStore.cardRecord)
        }
    }

    /// FTS5 string literal: double internal quotes, wrap in quotes. Neutralizes operator injection.
    private func ftsQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Body/name FTS token helper for E2's soft-narrow text pass. Unqualified `MATCH` (no
    /// `name :` / `body :` column filter) searches BOTH `name` and `body`, so a single query
    /// covers card-name matches AND attack-name matches (Plan 1 indexed attack names into
    /// `card_text.body`) — this is the "biggest win" narrowing signal from the OCR spike.
    /// Tokens shorter than 3 chars are dropped as too noisy for prefix MATCH; `[]` in ⇒ `[]` out
    /// (never falls back to matching everything).
    func cardIdsMatchingText(tokens: [String], limit: Int = 200) throws -> [String] {
        let usable = tokens.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return [] }
        let matchExpr = "(" + usable.map { "\(ftsQuoted($0))*" }.joined(separator: " OR ") + ")"
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT card_id FROM card_text
                WHERE card_text MATCH ?
                ORDER BY bm25(card_text) LIMIT ?
                """, arguments: [matchExpr, limit])
        }
    }
}
