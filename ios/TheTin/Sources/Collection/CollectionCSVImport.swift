import Foundation

// MARK: - RFC 4180 record iterator

/// Streams one CSV record at a time: quoted fields, "" escapes, quoted newlines, CRLF/LF/CR
/// line ends, UTF-8 BOM stripped, blank lines skipped. Records are never all materialized —
/// the import driver stops the moment the row cap trips.
/// ponytail: the file itself is held as one String (a 20k-row CSV is a few MB); switch to
/// InputStream chunking only if the row cap is ever raised by design.
struct CSVRecordIterator: IteratorProtocol {
    private var iter: String.UnicodeScalarView.Iterator
    private var peeked: Unicode.Scalar?
    private var done = false

    init(_ text: String) {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        iter = t.unicodeScalars.makeIterator()
    }

    private mutating func read() -> Unicode.Scalar? {
        if let p = peeked { peeked = nil; return p }
        return iter.next()
    }

    mutating func next() -> [String]? {
        if done { return nil }
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        while let c = read() {
            if inQuotes {
                if c == "\"" {
                    if let n = read() {
                        if n == "\"" { field.unicodeScalars.append(c) }   // escaped quote
                        else { inQuotes = false; peeked = n }
                    } else { inQuotes = false }   // dangling quote at EOF — field just ends
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == "," {
                fields.append(field)
                field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", let n = read(), n != "\n" { peeked = n }   // lone CR line end
                if fields.isEmpty && field.isEmpty { continue }          // blank line
                fields.append(field)
                return fields
            } else {
                field.unicodeScalars.append(c)
            }
        }
        done = true
        guard !fields.isEmpty || !field.isEmpty else { return nil }
        fields.append(field)   // trailing record without a final newline
        return fields
    }
}

// MARK: - Imported row (one CSV row lifted to a common shape, pre-matching)

/// Canonical values: `variant`/`condition`/`grade` are CardVariant/CardCondition/Grade rawValues
/// (mappers translate third-party wording); `number` may still be the printed form ("042/102").
struct ImportedRow {
    var cardId: String? = nil        // The Tin only — authoritative
    var tcgplayerId: Int? = nil      // TCGplayer only
    var setName: String? = nil
    var setCode: String? = nil       // TCGplayer "BS" — long-shot direct try against our set ids
    var cardName: String? = nil
    var number: String? = nil
    var qty: Int = 1
    var variant: String? = nil
    var condition: String? = nil
    var grade: String? = nil
    var pricePaid: Double? = nil
    var acquiredAt: Date? = nil
    var acquiredFrom: String? = nil
    var addedAt: Date? = nil
    var note: String? = nil          // merged into acquiredFrom (e.g. "Grade: CGC 9.5")
}

enum MatchResult: Equatable {
    case matched(CardRecord)
    case unmatched(String)   // human-readable reason — lands verbatim in skipped-rows.csv
}

// MARK: - Card matcher

/// Resolves an ImportedRow to a catalog card: card_id → tcgplayer_id → set+number → set+name.
/// Set names are normalized (case/diacritics/punctuation-insensitive); per-set card lists are
/// cached so a 20k-row import does O(referenced sets) catalog reads, not O(rows).
final class CardMatcher {
    private let store: CatalogStore
    private let setIdByName: [String: String]
    private let setIds: Set<String>
    private let cardIdByTcgplayerId: [Int: String]
    private var cardsBySet: [String: [CardRecord]] = [:]

    init(store: CatalogStore) {
        self.store = store
        let sets = (try? store.sets()) ?? []
        var byName: [String: String] = [:]
        for s in sets where byName[Self.norm(s.name)] == nil { byName[Self.norm(s.name)] = s.id }
        setIdByName = byName
        setIds = Set(sets.map(\.id))
        // Built once (not per-row): store.card(tcgplayerId:) is an unindexed table scan, and
        // TCGplayer imports call this path for every row (up to the 20k-row cap).
        cardIdByTcgplayerId = (try? store.tcgplayerIdMap()) ?? [:]
    }

    /// Lowercased, diacritic-stripped, alphanumerics only — "Pokémon GO!" → "pokemongo".
    static func norm(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Printed number → catalog form: "042/102" → "42"; "TG20" stays "TG20".
    static func normNumber(_ s: String) -> String {
        var n = String(s.split(separator: "/").first ?? Substring(s))
            .trimmingCharacters(in: .whitespaces).uppercased()
        while n.count > 1, n.hasPrefix("0") { n.removeFirst() }
        return n
    }

    func match(_ row: ImportedRow) -> MatchResult {
        if let id = row.cardId {
            if let card = try? store.card(id: id) { return .matched(card) }
            return .unmatched("unknown card_id \(id)")
        }
        if let tid = row.tcgplayerId, let cardId = cardIdByTcgplayerId[tid],
           let card = try? store.card(id: cardId) {
            return .matched(card)   // a MISS falls through to set+number/name below
        }
        guard let setId = resolveSet(row) else {
            return .unmatched("set not found: \(row.setName ?? row.setCode ?? "?")")
        }
        let cards = cardsInSet(setId)
        if let number = row.number.map(Self.normNumber), !number.isEmpty,
           let hit = cards.first(where: { Self.normNumber($0.number) == number }) {
            return .matched(hit)
        }
        if let name = row.cardName.map(Self.norm) {
            let hits = cards.filter { Self.norm($0.name) == name }
            if hits.count == 1 { return .matched(hits[0]) }   // ambiguous names stay unmatched
        }
        return .unmatched("no match in \(setId) for \(row.cardName ?? "?") #\(row.number ?? "?")")
    }

    private func resolveSet(_ row: ImportedRow) -> String? {
        if let name = row.setName, let id = setIdByName[Self.norm(name)] { return id }
        if let code = row.setCode?.lowercased(), setIds.contains(code) { return code }
        return nil
    }

    private func cardsInSet(_ setId: String) -> [CardRecord] {
        if let cached = cardsBySet[setId] { return cached }
        let cards = (try? store.cards(inSet: setId)) ?? []
        cardsBySet[setId] = cards
        return cards
    }
}

// MARK: - Header index

/// Case-insensitive header → column lookup. Falls back to PREFIX matching so Collectr's dated
/// "Market Price (2026-01-15)" header still answers to "Market Price".
struct HeaderIndex {
    let headers: [String]
    private let exact: [String: Int]

    init(_ headers: [String]) {
        self.headers = headers.map { $0.trimmingCharacters(in: .whitespaces) }
        var m: [String: Int] = [:]
        for (i, h) in self.headers.enumerated() where m[h.lowercased()] == nil {
            m[h.lowercased()] = i
        }
        exact = m
    }

    func index(of name: String) -> Int? {
        exact[name.lowercased()] ?? headers.firstIndex { $0.lowercased().hasPrefix(name.lowercased()) }
    }

    func has(_ name: String) -> Bool { index(of: name) != nil }

    /// Trimmed value of the named column; nil when the column is absent, out of range, or empty.
    func value(_ name: String, in fields: [String]) -> String? {
        guard let i = index(of: name), i < fields.count else { return nil }
        let v = fields[i].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Shared field parsers

enum CSVField {
    /// "$1,234.56" → 1234.56 ($, thousands commas, stray whitespace).
    static func money(_ s: String?) -> Double? {
        guard let s else { return nil }
        return Double(s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces))
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
    private static let extraFormats: [DateFormatter] = ["MM/dd/yyyy", "M/d/yyyy"].map { fmt in
        let f = DateFormatter()
        f.dateFormat = fmt
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    /// ISO 8601 (with/without time), then US-style d/m/y forms. nil when nothing parses.
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFull.date(from: s) ?? isoDay.date(from: s) { return d }
        return extraFormats.lazy.compactMap { $0.date(from: s) }.first
    }

    /// "Near Mint"/"Lightly Played"… or already-short "NM" → CardCondition rawValue.
    static func condition(_ s: String?) -> String? {
        guard let s else { return nil }
        if let short = CardCondition(rawValue: s.uppercased()) { return short.rawValue }
        let t = s.lowercased()
        guard let full = Condition.allCases.first(where: { t.hasPrefix($0.rawValue.lowercased()) })
        else { return nil }
        return CardCondition.allCases.first { $0.catalog == full }?.rawValue
    }

    /// Printing text ("Holofoil", "Reverse Holo(foil)", "Master Ball Reverse Holo", "Normal",
    /// "1st Edition Holofoil", or a Tin rawValue) → CardVariant rawValue, via the same
    /// substring rules the app uses for PPT printing keys. Unmapped → nil (spec: left nil).
    static func variant(_ s: String?) -> String? {
        guard let s else { return nil }
        if let v = CardVariant(rawValue: s) { return v.rawValue }   // Tin round-trip
        return CardVariant.allCases.first { $0.matches(printing: s) }?.rawValue
    }

    /// "Ungraded" → (nil, nil). "PSA 10" → ("psa10", nil) when the value exists in our Grade
    /// enum. Everything else (CGC/BGS/ACE anything, PSA 8, …) → (nil, "Grade: <original>") —
    /// preserved as a note, never silently dropped.
    static func grade(_ s: String?) -> (grade: String?, note: String?) {
        guard let s, s.lowercased() != "ungraded" else { return (nil, nil) }
        if let g = Grade(rawValue: s.lowercased()) { return (g.rawValue, nil) }   // Tin "psa10"
        let parts = s.split(separator: " ")
        if parts.count == 2, parts[0].uppercased() == "PSA",
           let g = Grade(rawValue: "psa\(parts[1])") {
            return (g.rawValue, nil)
        }
        return (nil, "Grade: \(s)")
    }
}

// MARK: - Format table

enum RowOutcome {
    case row(ImportedRow)
    case skip(String)   // reason — lands verbatim in skipped-rows.csv
}

struct CSVImportFormat {
    let name: String
    let experimental: Bool
    let detect: (HeaderIndex) -> Bool
    let map: (HeaderIndex, [String]) -> RowOutcome
}

// MARK: - Import driver

enum CollectionCSVImport {
    static let rowCap = 20_000

    enum ImportError: LocalizedError, Equatable {
        case emptyFile
        case unrecognizedFormat
        case tooManyRows

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "The file is empty."
            case .unrecognizedFormat:
                return "Unrecognized CSV format. Supported: The Tin, Collectr, TCGplayer Card List, TCG Collector."
            case .tooManyRows:
                return "Too many rows — imports are capped at \(rowCap). Split the file and retry."
            }
        }
    }

    struct SkippedRow: Equatable {
        let fields: [String]
        let reason: String
    }

    struct Result {
        let formatName: String
        let experimental: Bool
        let headers: [String]
        var entries: [CollectionEntry] = []   // groupId "" — caller re-homes into the import divider
        var skipped: [SkippedRow] = []

        var summary: String {
            var s = "\(entries.count) cards imported, \(skipped.count) rows skipped."
            let sealed = skipped.filter { $0.reason.hasPrefix("sealed") }.count
            if sealed > 0 { s += " \(sealed) sealed products (not supported)." }
            return s
        }
    }

    /// Detection order matters: Tin first (its header would also satisfy the keyword sniffer),
    /// then the two verbatim third-party headers, then the TCG Collector sniffer as catch-all.
    /// A new format (e.g. Dex — deferred: semicolon-delimited, possibly UTF-16) is one entry here.
    static let formats: [CSVImportFormat] = [tin, collectr, tcgplayer, tcgCollector]

    static func importCSV(_ text: String, matcher: CardMatcher, now: Date = Date()) throws -> Result {
        var records = CSVRecordIterator(text)
        guard let headerFields = records.next() else { throw ImportError.emptyFile }
        let header = HeaderIndex(headerFields)
        guard let format = formats.first(where: { $0.detect(header) }) else {
            throw ImportError.unrecognizedFormat
        }
        var result = Result(formatName: format.name, experimental: format.experimental,
                            headers: header.headers)
        var count = 0
        while let fields = records.next() {
            count += 1
            if count > rowCap { throw ImportError.tooManyRows }
            guard fields.count == header.headers.count else {
                result.skipped.append(SkippedRow(fields: fields,
                    reason: "malformed row (\(fields.count) of \(header.headers.count) columns)"))
                continue
            }
            switch format.map(header, fields) {
            case .skip(let reason):
                result.skipped.append(SkippedRow(fields: fields, reason: reason))
            case .row(let row):
                switch matcher.match(row) {
                case .unmatched(let reason):
                    result.skipped.append(SkippedRow(fields: fields, reason: reason))
                case .matched(let card):
                    result.entries.append(entry(row, card: card, now: now))
                }
            }
        }
        return result
    }

    private static func entry(_ row: ImportedRow, card: CardRecord, now: Date) -> CollectionEntry {
        let from = [row.acquiredFrom, row.note].compactMap { $0 }.joined(separator: " · ")
        return CollectionEntry(id: UUID().uuidString, cardId: card.id, groupId: "",
                               qty: max(1, row.qty), condition: row.condition, grade: row.grade,
                               pricePaid: row.pricePaid, acquiredAt: row.acquiredAt,
                               acquiredFrom: from.isEmpty ? nil : from,
                               addedAt: row.addedAt ?? now, variant: row.variant)
    }

    /// skipped-rows.csv: the file's original columns + a trailing skip_reason column.
    static func skippedRowsCSV(_ result: Result) -> Data {
        CollectionCSV.data([result.headers + ["skip_reason"]]
                           + result.skipped.map { $0.fields + [$0.reason] })
    }

    // MARK: The Tin format — lossless round-trip; card_id is authoritative.
    // Detection needs card_id AND qty so a *wishlist* export (no qty) is rejected instead of
    // being imported as owned cards.

    static let tin = CSVImportFormat(
        name: "The Tin", experimental: false,
        detect: { $0.has("card_id") && $0.has("qty") },
        map: { h, f in
            guard let id = h.value("card_id", in: f) else { return .skip("missing card_id") }
            var row = ImportedRow(cardId: id)
            row.qty = h.value("qty", in: f).flatMap(Int.init) ?? 1
            row.variant = CSVField.variant(h.value("variant", in: f))
            row.condition = CSVField.condition(h.value("condition", in: f))
            let g = CSVField.grade(h.value("grade", in: f))
            row.grade = g.grade
            row.note = g.note
            row.pricePaid = CSVField.money(h.value("price_paid", in: f))
            row.acquiredAt = CSVField.date(h.value("acquired_at", in: f))
            row.acquiredFrom = h.value("acquired_from", in: f)
            row.addedAt = CSVField.date(h.value("added_at", in: f))
            return .row(row)   // divider/current_value/value_as_of columns intentionally ignored
        })

    // MARK: Collectr — verbatim 16-column header, no IDs of any kind. Columns are read BY NAME
    // because newer exports append an optional Language column. HeaderIndex's prefix fallback
    // covers the dated "Market Price (2026-01-15)" header (we never read it, but it must not
    // break by-name lookups of the other columns).

    static let collectr = CSVImportFormat(
        name: "Collectr", experimental: false,
        detect: { $0.has("Portfolio Name") && $0.has("Product Name") },
        map: { h, f in
            if let cat = h.value("Category", in: f), CardMatcher.norm(cat) != "pokemon" {
                return .skip("non-Pokémon category (\(cat))")
            }
            if let lang = h.value("Language", in: f), CardMatcher.norm(lang) != "english" {
                return .skip("non-English language (\(lang))")
            }
            let name = h.value("Product Name", in: f)
            let set = h.value("Set", in: f)
            // Without a Language column, Collectr marks Japanese cards "(JP)" in name/set.
            // Our catalog is English-only — doomed match, so skip with an honest reason.
            if (name ?? "").contains("(JP)") || (set ?? "").contains("(JP)") {
                return .skip("Japanese card — not in the catalog")
            }
            // Empty Card Number = sealed product (booster box, ETB, …). Counted separately
            // in Result.summary via the "sealed" reason prefix.
            guard let number = h.value("Card Number", in: f) else {
                return .skip("sealed product (no card number)")
            }
            var row = ImportedRow()
            row.setName = set
            row.cardName = name
            row.number = number   // printed "4/102" — the matcher takes the part before "/"
            row.qty = h.value("Quantity", in: f).flatMap(Int.init) ?? 1
            row.variant = CSVField.variant(h.value("Variance", in: f))
            row.condition = CSVField.condition(h.value("Card Condition", in: f))
            let g = CSVField.grade(h.value("Grade", in: f))
            row.grade = g.grade
            row.note = g.note
            row.pricePaid = CSVField.money(h.value("Average Cost Paid", in: f))
            row.addedAt = CSVField.date(h.value("Date Added", in: f))
            row.acquiredFrom = h.value("Notes", in: f)
            return .row(row)   // "Market Price"/"Price Override"/"Watchlist" intentionally ignored
        })

    // MARK: TCGplayer app "Card List" — the best third-party format: Product ID matches our
    // tcgplayer_id column directly; fallback is Set (full name) + zero-padded Card Number,
    // then name — all handled inside CardMatcher.

    static let tcgplayer = CSVImportFormat(
        name: "TCGplayer Card List", experimental: false,
        detect: { $0.has("Product ID") && $0.has("Simple Name") },
        map: { h, f in
            if let lang = h.value("Language", in: f), CardMatcher.norm(lang) != "english" {
                return .skip("non-English language (\(lang))")
            }
            var row = ImportedRow()
            row.tcgplayerId = h.value("Product ID", in: f).flatMap(Int.init)
            row.setName = h.value("Set", in: f)
            row.setCode = h.value("Set Code", in: f)
            row.cardName = h.value("Simple Name", in: f) ?? h.value("Name", in: f)
            row.number = h.value("Card Number", in: f)   // "042/102" — matcher normalizes
            row.qty = h.value("Quantity", in: f).flatMap(Int.init) ?? 1
            row.variant = CSVField.variant(h.value("Printing", in: f))
            row.condition = CSVField.condition(h.value("Condition", in: f))
            // "Price"/"Price Each" are market prices at export time, NOT cost paid — ignored.
            return .row(row)
        })

    // MARK: TCG Collector — EXPERIMENTAL. Exact headers unrecoverable (spec: positional
    // evidence only), so columns are found by keyword. Pin exact fixtures when a real export
    // is obtained; until then Result.experimental drives an "experimental" tag in the UI.

    static let tcgCollector = CSVImportFormat(
        name: "TCG Collector", experimental: true,
        detect: { h in
            sniff(h, ["name"]) != nil && sniff(h, ["number", "no."]) != nil
                && sniff(h, ["expansion", "set"]) != nil && sniff(h, ["quantity", "qty"]) != nil
        },
        map: { h, f in
            func v(_ keys: [String]) -> String? {
                guard let i = sniff(h, keys), i < f.count else { return nil }
                let s = f[i].trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            var row = ImportedRow()
            row.setName = v(["expansion", "set"])
            row.cardName = v(["card name", "name"])
            row.number = v(["number", "no."])
            row.qty = v(["quantity", "qty"]).flatMap(Int.init) ?? 1
            row.variant = CSVField.variant(v(["variant"]))
            row.condition = CSVField.condition(v(["condition"]))
            return .row(row)
        })

    /// First column whose header matches a keyword — exact (case-insensitive) match beats
    /// contains, and keywords are tried in order, so v(["card name", "name"]) finds "Card Name"
    /// before "Expansion Name" can steal the contains-"name" match.
    private static func sniff(_ h: HeaderIndex, _ keywords: [String]) -> Int? {
        for k in keywords {
            if let i = h.headers.firstIndex(where: { $0.lowercased() == k }) { return i }
        }
        for k in keywords {
            if let i = h.headers.firstIndex(where: { $0.lowercased().contains(k) }) { return i }
        }
        return nil
    }
}
