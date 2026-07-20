import type { Database } from "better-sqlite3";

/**
 * Parse + ingest for PPT's Business-tier bulk EXPORT CSVs (`GET /api/v2/export?type=…`).
 *
 * Column headers below are taken from PPT's api-reference docs (verified 2026-07-11). The bulk
 * export is SPLIT: `cards` carries raw market/low only; graded prices come from `ebay`;
 * population from `population`; sealed from `sealed`. Per-condition (NM/LP/MP) prices and EUR are
 * NOT in any export (REST /cards only) — the hybrid pipeline still fetches those separately, so
 * this module intentionally never writes price_by_condition / raw_eur.
 *
 * Everything joins on `tcgPlayerId`, which our `card` table carries as `tcgplayer_id`.
 *
 * Verified against real dumps (probe, 2026-07-11): `cards` tcgPlayerId is the printing-specific
 * SKU → UNIQUE per row (1:1 join); prices are plain dollars; 302→Vercel Blob. `ebay.grade` is
 * lowercase no-space ("psa10","psa8","cgc6"); we take `medianPrice` as the headline graded price
 * because `smartMarketPrice` can diverge ~2x from actual sales. Export quota is 2 downloads/day.
 * NOT yet probed (quota): exact `sealed`/`population` columns (documented, low-risk) and the null
 * representation (assumed empty field).
 */

// ---------- RFC-4180 CSV parser (header row + quoted fields with commas/newlines/"" escapes) ----------

/** Parse CSV text into header-keyed records. Assumes the first row is the header (PPT exports
 *  include one). Tolerates quoted fields containing commas, CRLF, and doubled-quote escapes. */
export function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let field = "";
  let row: string[] = [];
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } // "" → literal "
        else inQuotes = false;
      } else field += c;
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      row.push(field); field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++; // CRLF
      row.push(field); field = "";
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); if (row.length > 1 || row[0] !== "") rows.push(row); }

  if (rows.length === 0) return [];
  const header = rows[0];
  return rows.slice(1).map((r) => {
    const rec: Record<string, string> = {};
    header.forEach((h, idx) => { rec[h] = r[idx] ?? ""; });
    return rec;
  });
}

function numOrNull(s: string | undefined): number | null {
  if (s == null) return null;
  const t = s.trim();
  if (t === "") return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

function intOrNull(s: string | undefined): number | null {
  const n = numOrNull(s);
  return n == null ? null : Math.trunc(n);
}

// ---------- Typed row shapes (documented export columns) ----------

export interface CardsExportRow {
  tcgPlayerId: number; name: string; setId: string; cardNumber: string;
  marketPrice: number | null; lowPrice: number | null; sellers: number | null; lastPriceUpdate: string;
}
export interface SealedExportRow {
  tcgPlayerId: number; name: string; setId: string; productType: string;
  marketPrice: number | null; lowPrice: number | null; lastPriceUpdate: string;
}
export interface EbayExportRow {
  tcgPlayerId: number; grade: string;
  smartMarketPrice: number | null; medianPrice: number | null; averagePrice: number | null;
}
export interface PopulationExportRow {
  tcgPlayerId: number; grader: string;
  totalPopulation: number | null; gemRate: number | null;
  /** grade label ("10","9.5","9",…) → count, from the g1..g10/g9_5 columns. */
  grades: Record<string, number>;
}

// ---------- Per-dataset parsers ----------

export function parseCardsExport(csv: string): CardsExportRow[] {
  return parseCsv(csv).flatMap((r) => {
    const id = intOrNull(r.tcgPlayerId);
    if (id == null) return [];
    return [{
      tcgPlayerId: id, name: r.name ?? "", setId: r.setId ?? "", cardNumber: r.cardNumber ?? "",
      marketPrice: numOrNull(r.marketPrice), lowPrice: numOrNull(r.lowPrice), sellers: intOrNull(r.sellers),
      lastPriceUpdate: r.lastPriceUpdate ?? "",
    }];
  });
}

export function parseSealedExport(csv: string): SealedExportRow[] {
  return parseCsv(csv).flatMap((r) => {
    const id = intOrNull(r.tcgPlayerId);
    if (id == null) return [];
    return [{
      tcgPlayerId: id, name: r.name ?? "", setId: r.setId ?? "", productType: r.productType ?? "",
      marketPrice: numOrNull(r.marketPrice), lowPrice: numOrNull(r.lowPrice),
      lastPriceUpdate: r.lastPriceUpdate ?? "",
    }];
  });
}

export function parseEbayExport(csv: string): EbayExportRow[] {
  return parseCsv(csv).flatMap((r) => {
    const id = intOrNull(r.tcgPlayerId);
    if (id == null || !r.grade) return [];
    return [{
      tcgPlayerId: id, grade: r.grade,
      smartMarketPrice: numOrNull(r.smartMarketPrice), medianPrice: numOrNull(r.medianPrice),
      averagePrice: numOrNull(r.averagePrice),
    }];
  });
}

const POP_GRADE_COLUMNS: Record<string, string> = {
  g1: "1", g2: "2", g3: "3", g4: "4", g5: "5", g6: "6", g7: "7", g8: "8", g9: "9", g9_5: "9.5", g10: "10",
  // Specialty designations (documented export columns): PSA Authentic-only, BGS Pristine 10 /
  // Perfect "Black Label". Zero counts are dropped by the existing >0 filter.
  auth: "Auth", pristine: "Pristine", perfect: "Perfect",
};

export function parsePopulationExport(csv: string): PopulationExportRow[] {
  return parseCsv(csv).flatMap((r) => {
    const id = intOrNull(r.tcgPlayerId);
    if (id == null) return [];
    const grades: Record<string, number> = {};
    for (const [col, label] of Object.entries(POP_GRADE_COLUMNS)) {
      const n = intOrNull(r[col]);
      if (n != null && n > 0) grades[label] = n;
    }
    return [{
      tcgPlayerId: id, grader: r.grader ?? "PSA",
      totalPopulation: intOrNull(r.totalPopulation), gemRate: numOrNull(r.gemRate), grades,
    }];
  });
}

// ---------- Ingest into an existing catalog DB (join by tcgplayer_id) ----------

export const PSA_COLUMNS = ["psa1", "psa2", "psa3", "psa4", "psa5", "psa6", "psa7", "psa8", "psa9", "psa10"] as const;
export type PsaColumn = (typeof PSA_COLUMNS)[number];

/** `ebay.grade` string → our psa column. Real dumps use lowercase "psa10"/"psa8"/"cgc6"; the
 *  regex tolerates spaced/upper forms too. Every integer PSA grade 1-10 has a column in
 *  price_latest; half grades and other graders (BGS/CGC/SGC) are ignored here — they still
 *  land in graded_history via the REST path. */
export function ebayGradeToPsaColumn(grade: string): PsaColumn | null {
  const m = grade.match(/(\d+(?:[._]\d+)?)/);
  if (!m) return null;
  if (!/psa/i.test(grade) && !/^\s*\d/.test(grade)) return null; // require PSA or a bare number
  const n = Number(m[1].replace("_", "."));
  if (!Number.isInteger(n) || n < 1 || n > 10) return null; // half grades / out-of-range
  return `psa${n}` as PsaColumn;
}

export interface ExportInputs {
  cards?: CardsExportRow[];
  ebay?: EbayExportRow[];
  sealed?: SealedExportRow[];
  population?: PopulationExportRow[];
  asOf: string; // ISO date, e.g. "2026-07-11"
}

export interface ExportApplyStats {
  rawRows: number; gradedRows: number; sealedRows: number; popRows: number; unmatched: number;
  gradedPrintingRows: number;
}

function buildIdByTcgFromDb(db: Database): Map<number, string> {
  const idByTcg = new Map<number, string>();
  for (const row of db.prepare("SELECT id, tcgplayer_id FROM card WHERE tcgplayer_id IS NOT NULL").all() as
       { id: string; tcgplayer_id: number }[]) {
    if (!idByTcg.has(row.tcgplayer_id)) idByTcg.set(row.tcgplayer_id, row.id);
  }
  return idByTcg;
}

/**
 * Apply parsed bulk-export rows to a catalog DB whose `card` table is already populated (with
 * `tcgplayer_id`). Writes: price_latest.raw_usd (cards), price_latest psaN (ebay graded),
 * sealed_product (sealed), population (population). Rows whose tcgPlayerId maps to no card are
 * counted in `unmatched` and skipped (sealed products are keyed by tcgplayer_id directly, so they
 * are never "unmatched"). Never touches price_by_condition / raw_eur — those stay on the REST path.
 */
export function applyExport(db: Database, inputs: ExportInputs, idByTcgOverride?: Map<number, string>,
  skuMeta?: Map<number, { printing: string; priority: number }>): ExportApplyStats {
  const stats: ExportApplyStats = {
    rawRows: 0, gradedRows: 0, sealedRows: 0, popRows: 0, unmatched: 0, gradedPrintingRows: 0,
  };

  // tcgPlayerId → our card id. The build pipeline passes a map covering EVERY printing SKU of
  // each card (a card can have several tcgPlayerIds); without an override we fall back to the
  // single `card.tcgplayer_id` column (fine for tests / already-stamped catalogs).
  const idByTcg = idByTcgOverride ?? buildIdByTcgFromDb(db);

  // Additive per-printing graded table (labels only exist when skuMeta is supplied — the
  // build pipeline passes it; bare callers keep today's exact behavior).
  db.exec(`CREATE TABLE IF NOT EXISTS graded_by_printing(card_id TEXT NOT NULL, printing TEXT NOT NULL,
    grade TEXT NOT NULL, usd REAL NOT NULL, as_of TEXT NOT NULL, PRIMARY KEY(card_id, printing, grade));
    CREATE INDEX IF NOT EXISTS idx_graded_by_printing_card ON graded_by_printing(card_id)`);
  const insGbp = db.prepare(
    "INSERT OR REPLACE INTO graded_by_printing(card_id, printing, grade, usd, as_of) VALUES (?,?,?,?,?)");
  const prio = (tcg: number) => skuMeta?.get(tcg)?.priority ?? Number.MAX_SAFE_INTEGER;

  const plCols = new Set((db.pragma("table_info(price_latest)") as { name: string }[]).map((c) => c.name));
  for (const col of ["sellers", "listings"]) {
    if (!plCols.has(col)) db.exec(`ALTER TABLE price_latest ADD COLUMN ${col} INTEGER`);
  }
  if (!plCols.has("low_usd")) db.exec(`ALTER TABLE price_latest ADD COLUMN low_usd REAL`);

  const upRaw = db.prepare(`INSERT INTO price_latest(card_id, raw_usd, sellers, low_usd, as_of) VALUES (@id,@raw,@sellers,@low,@as_of)
    ON CONFLICT(card_id) DO UPDATE SET raw_usd=@raw, sellers=COALESCE(@sellers, sellers), low_usd=COALESCE(@low, low_usd), as_of=@as_of`);
  const upGraded = db.prepare(`INSERT INTO price_latest(card_id, ${PSA_COLUMNS.join(", ")}, as_of)
    VALUES (@id,${PSA_COLUMNS.map((c) => `@${c}`).join(",")},@as_of)
    ON CONFLICT(card_id) DO UPDATE SET
      ${PSA_COLUMNS.map((c) => `${c}=COALESCE(@${c},${c})`).join(", ")}, as_of=@as_of`);
  const upSealed = db.prepare(`INSERT OR REPLACE INTO
    sealed_product(tcgplayer_id, name, set_id, product_type, market_usd, low_usd, as_of)
    VALUES (@tcg,@name,@set,@type,@market,@low,@as_of)`);
  const insPop = db.prepare(`INSERT OR REPLACE INTO
    population(card_id, grader, grade, count, gem_rate, total_population, as_of) VALUES (?,?,?,?,?,?,?)`);

  const tx = db.transaction(() => {
    // One raw_usd per card: the highest-priority (lowest number) SKU that has a market price.
    // Without skuMeta every row ties at MAX_SAFE_INTEGER and `<` keeps the FIRST row, which is
    // still deterministic (input order) — callers that care pass skuMeta.
    const bestRaw = new Map<string, { p: number; price: number; sellers: number | null; low: number | null }>();
    for (const c of inputs.cards ?? []) {
      const id = idByTcg.get(c.tcgPlayerId);
      if (!id) { stats.unmatched++; continue; }
      if (c.marketPrice == null) continue;
      const cur = bestRaw.get(id);
      if (!cur || prio(c.tcgPlayerId) < cur.p) {
        bestRaw.set(id, { p: prio(c.tcgPlayerId), price: c.marketPrice, sellers: c.sellers, low: c.lowPrice });
      }
    }
    for (const [id, { price, sellers, low }] of bestRaw) {
      upRaw.run({ id, raw: price, sellers, low, as_of: inputs.asOf });
      stats.rawRows++;
    }

    // Collapse ebay rows (one per grade) into one psa* update per card.
    const emptyPsa = (): Record<PsaColumn, number | null> =>
      Object.fromEntries(PSA_COLUMNS.map((c) => [c, null])) as Record<PsaColumn, number | null>;
    const psaByCard = new Map<string, Record<PsaColumn, number | null>>();
    const psaPrio = new Map<string, number>(); // `${cardId}|${col}` → priority that set it
    for (const e of inputs.ebay ?? []) {
      const id = idByTcg.get(e.tcgPlayerId);
      if (!id) { stats.unmatched++; continue; }
      // medianPrice is the headline: smartMarketPrice can diverge ~2x from real sales (probed).
      const price = e.medianPrice ?? e.smartMarketPrice ?? e.averagePrice;
      if (price == null) continue;
      const meta = skuMeta?.get(e.tcgPlayerId);
      if (meta) {
        insGbp.run(id, meta.printing, e.grade, price, inputs.asOf);
        stats.gradedPrintingRows++;
      }
      const col = ebayGradeToPsaColumn(e.grade);
      if (!col) continue;
      const k = `${id}|${col}`;
      const cur = psaPrio.get(k);
      if (cur != null && prio(e.tcgPlayerId) >= cur) continue;
      psaPrio.set(k, prio(e.tcgPlayerId));
      const g = psaByCard.get(id) ?? emptyPsa();
      g[col] = price;
      psaByCard.set(id, g);
    }
    for (const [id, g] of psaByCard) {
      upGraded.run({ id, ...g, as_of: inputs.asOf });
      stats.gradedRows++;
    }

    for (const s of inputs.sealed ?? []) {
      upSealed.run({ tcg: s.tcgPlayerId, name: s.name, set: s.setId || null, type: s.productType || null,
        market: s.marketPrice, low: s.lowPrice, as_of: inputs.asOf });
      stats.sealedRows++;
    }

    for (const p of inputs.population ?? []) {
      const id = idByTcg.get(p.tcgPlayerId);
      if (!id) { stats.unmatched++; continue; }
      for (const [grade, count] of Object.entries(p.grades)) {
        insPop.run(id, p.grader, grade, count, p.gemRate, p.totalPopulation, inputs.asOf);
        stats.popRows++;
      }
    }
  });
  tx();
  return stats;
}
