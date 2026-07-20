// functions/src/pipeline/overnight-sweep-core.ts
import type { Database as Db } from "better-sqlite3";
import { normalizeNumber } from "./matcher";
import { PSA_COLUMNS } from "./ppt-export";
import { parseWeeklyHistory, parseConditionHistory, parseLatestByCondition, parseLatestByVariant, parseMatrix, parseLiquidity, parseConditionSales } from "./ppt-history";
import { parseGradedSales } from "./ppt-graded";
import type { PptEnrichmentCard } from "../upstream/ppt";
import type { PopulationRow } from "./ppt-population";

export interface SweepClient {
  getSetEnrichment(setName: string): Promise<PptEnrichmentCard[]>;
  getPopulation(tcgPlayerIds: number[]): Promise<PopulationRow[]>;
}
export interface OvernightSet { setId: string; pptName: string; }
export interface OvernightLedger {
  setsDone: Set<string>; popBatchesDone: Set<string>;
  markSet(id: string): void; markPopBatch(key: string): void;
}
export interface OvernightOptions { populationEnabled: boolean; asOf: string; }
export interface OvernightSummary {
  setsDone: number; historyRows: number; gradedRows: number; popRows: number;
  condHistoryRows: number; byCondRows: number; byVariantRows: number; matrixRows: number; condSalesRows: number;
  liquidityRows: number; gradedSalesRows: number;
  stoppedEarly: boolean; stopReason?: string;
}

interface OurCard { id: string; number: string; name: string; }
const normName = (n: string) => n.toLowerCase().replace(/[^a-z0-9]/g, "");

const DDL = `
CREATE TABLE IF NOT EXISTS population(card_id TEXT NOT NULL, grader TEXT NOT NULL, grade TEXT NOT NULL,
  count INTEGER, gem_rate REAL, total_population INTEGER, as_of TEXT NOT NULL, PRIMARY KEY(card_id, grader, grade));
CREATE TABLE IF NOT EXISTS graded_history(card_id TEXT NOT NULL, grade TEXT NOT NULL, date TEXT NOT NULL,
  usd REAL NOT NULL, PRIMARY KEY(card_id, grade, date));
CREATE INDEX IF NOT EXISTS idx_population_card ON population(card_id);
CREATE INDEX IF NOT EXISTS idx_graded_history_card ON graded_history(card_id);
CREATE TABLE IF NOT EXISTS price_history_cond(card_id TEXT NOT NULL, condition TEXT NOT NULL, date TEXT NOT NULL,
  raw_usd REAL NOT NULL, PRIMARY KEY(card_id, condition, date));
CREATE TABLE IF NOT EXISTS price_by_condition(card_id TEXT NOT NULL, condition TEXT NOT NULL, usd REAL NOT NULL,
  as_of TEXT NOT NULL, PRIMARY KEY(card_id, condition));
CREATE TABLE IF NOT EXISTS price_by_variant(card_id TEXT NOT NULL, printing TEXT NOT NULL, usd REAL NOT NULL,
  as_of TEXT NOT NULL, PRIMARY KEY(card_id, printing));
CREATE TABLE IF NOT EXISTS price_matrix(card_id TEXT NOT NULL, printing TEXT NOT NULL,
  condition TEXT NOT NULL, usd REAL NOT NULL, as_of TEXT NOT NULL,
  PRIMARY KEY(card_id, printing, condition));
CREATE INDEX IF NOT EXISTS idx_price_history_cond_card ON price_history_cond(card_id);
CREATE INDEX IF NOT EXISTS idx_price_by_condition_card ON price_by_condition(card_id);
CREATE INDEX IF NOT EXISTS idx_price_by_variant_card ON price_by_variant(card_id);
CREATE INDEX IF NOT EXISTS idx_price_matrix_card ON price_matrix(card_id);
CREATE TABLE IF NOT EXISTS graded_sales(card_id TEXT NOT NULL, grade TEXT NOT NULL,
  sales_count INTEGER NOT NULL, confidence TEXT, as_of TEXT NOT NULL, PRIMARY KEY(card_id, grade));
CREATE INDEX IF NOT EXISTS idx_graded_sales_card ON graded_sales(card_id);`;

export async function runOvernightSweep(
  db: Db, client: SweepClient, sets: OvernightSet[], ledger: OvernightLedger,
  opts: OvernightOptions, isStopError: (e: unknown) => boolean,
): Promise<OvernightSummary> {
  db.exec(DDL);
  const plCols = new Set((db.pragma("table_info(price_latest)") as { name: string }[]).map((c) => c.name));
  for (const col of ["sellers", "listings"]) {
    if (!plCols.has(col)) db.exec(`ALTER TABLE price_latest ADD COLUMN ${col} INTEGER`);
  }
  const pbcCols = new Set((db.pragma("table_info(price_by_condition)") as { name: string }[]).map((c) => c.name));
  if (!pbcCols.has("sales_count")) db.exec(`ALTER TABLE price_by_condition ADD COLUMN sales_count INTEGER`);
  const insHist = db.prepare("INSERT OR REPLACE INTO price_history(card_id, date, raw_usd) VALUES (?,?,?)");
  const upGraded = db.prepare(`INSERT INTO price_latest(card_id, ${PSA_COLUMNS.join(", ")}, as_of)
    VALUES (@id,${PSA_COLUMNS.map((c) => `@${c}`).join(",")},@as_of)
    ON CONFLICT(card_id) DO UPDATE SET ${PSA_COLUMNS.map((c) => `${c}=@${c}`).join(", ")}, as_of=@as_of`);
  const insGh = db.prepare("INSERT OR REPLACE INTO graded_history(card_id, grade, date, usd) VALUES (?,?,?,?)");
  const insPop = db.prepare(`INSERT OR REPLACE INTO population(card_id, grader, grade, count, gem_rate, total_population, as_of)
    VALUES (?,?,?,?,?,?,?)`);
  const insHistCond = db.prepare("INSERT OR REPLACE INTO price_history_cond(card_id, condition, date, raw_usd) VALUES (?,?,?,?)");
  const insByCond = db.prepare("INSERT OR REPLACE INTO price_by_condition(card_id, condition, usd, as_of) VALUES (?,?,?,?)");
  const upCondSales = db.prepare("UPDATE price_by_condition SET sales_count=? WHERE card_id=? AND condition=?");
  const insByVariant = db.prepare("INSERT OR REPLACE INTO price_by_variant(card_id, printing, usd, as_of) VALUES (?,?,?,?)");
  const insMatrix = db.prepare("INSERT OR REPLACE INTO price_matrix(card_id, printing, condition, usd, as_of) VALUES (?,?,?,?,?)");
  const upLiquidity = db.prepare(`INSERT INTO price_latest(card_id, sellers, listings, as_of)
    VALUES (@id,@sellers,@listings,@as_of)
    ON CONFLICT(card_id) DO UPDATE SET
      sellers=COALESCE(@sellers, sellers), listings=COALESCE(@listings, listings)`);
  const insGs = db.prepare("INSERT OR REPLACE INTO graded_sales(card_id, grade, sales_count, confidence, as_of) VALUES (?,?,?,?,?)");
  const ourStmt = db.prepare("SELECT id, number, name FROM card WHERE set_id = ?");

  const sum: OvernightSummary = {
    setsDone: 0, historyRows: 0, gradedRows: 0, popRows: 0, condHistoryRows: 0, byCondRows: 0, byVariantRows: 0, matrixRows: 0, condSalesRows: 0, liquidityRows: 0, gradedSalesRows: 0, stoppedEarly: false,
  };

  // ---- Phase A: per set (history + graded) ----
  for (const s of sets) {
    if (ledger.setsDone.has(s.setId)) continue;
    const our = ourStmt.all(s.setId) as OurCard[];
    const byNum = new Map<string, OurCard[]>();
    for (const c of our) { const k = normalizeNumber(c.number); (byNum.get(k) ?? byNum.set(k, []).get(k)!).push(c); }

    let cards: PptEnrichmentCard[];
    try { cards = await client.getSetEnrichment(s.pptName); }
    catch (e) { if (isStopError(e)) return { ...sum, stoppedEarly: true, stopReason: (e as Error).message }; throw e; }

    const write = db.transaction((list: PptEnrichmentCard[]) => {
      for (const pc of list) {
        const cands = byNum.get(normalizeNumber(pc.cardNumber)) ?? [];
        const m = cands.length === 1 ? cands[0] : cands.find((c) => normName(c.name) === normName(pc.name)) ?? null;
        if (!m) continue;
        for (const wp of parseWeeklyHistory(pc.priceHistory)) { insHist.run(m.id, wp.date, wp.rawUsd); sum.historyRows++; }
        const g = pc.gradedLatest;
        // gradedLatest may carry many grades (cgc/bgs/ace/...), but price_latest only stores
        // integer PSA grades — gate on those alone so a card with only non-psa grades doesn't
        // write an all-null phantom row. (The full grade set still lands in graded_history via
        // gradedSeries below.)
        const psaVals = Object.fromEntries(PSA_COLUMNS.map((c) => [c, g[c] ?? null]));
        if (PSA_COLUMNS.some((c) => psaVals[c] != null)) {
          upGraded.run({ id: m.id, ...psaVals, as_of: opts.asOf });
          sum.gradedRows++;
        }
        // Always write whatever series each card has — parseGradedHistory yields [] for cards
        // without eBay sales, so there is nothing to gate. (A probe-driven writeGradedHistory
        // opt-in used to sit here; it sampled ONE card and latched graded_history off for the
        // whole sweep every night the sample happened to have no sales.)
        for (const p of pc.gradedSeries) insGh.run(m.id, p.grade, p.date, p.usd);
        // Parallel, app-compat-safe tables: ALL ungraded conditions (Near Mint, Lightly Played,
        // Moderately Played, Heavily Played, Damaged). Does not touch price_history/price_latest.
        for (const s of parseConditionHistory(pc.priceHistory)) {
          for (const pt of s.points) { insHistCond.run(m.id, s.condition, pt.date, pt.rawUsd); sum.condHistoryRows++; }
        }
        for (const cl of parseLatestByCondition(pc.pricesRaw)) {
          insByCond.run(m.id, cl.condition, cl.usd, opts.asOf); sum.byCondRows++;
        }
        for (const cs of parseConditionSales(pc.priceHistory, opts.asOf)) {
          upCondSales.run(cs.salesCount, m.id, cs.condition); sum.condSalesRows++;
        }
        for (const vl of parseLatestByVariant(pc.pricesRaw)) {
          insByVariant.run(m.id, vl.printing, vl.usd, opts.asOf); sum.byVariantRows++;
        }
        for (const cell of parseMatrix(pc.pricesRaw)) {
          insMatrix.run(m.id, cell.printing, cell.condition, cell.usd, opts.asOf); sum.matrixRows++;
        }
        const liq = parseLiquidity(pc.pricesRaw);
        if (liq.sellers != null || liq.listings != null) {
          upLiquidity.run({ id: m.id, sellers: liq.sellers, listings: liq.listings, as_of: opts.asOf });
          sum.liquidityRows++;
        }
        for (const gs of parseGradedSales(pc.ebayRaw)) {
          insGs.run(m.id, gs.grade, gs.salesCount, gs.confidence, opts.asOf);
          sum.gradedSalesRows++;
        }
      }
    });
    write(cards);
    ledger.markSet(s.setId); sum.setsDone++;
  }

  // ---- Phase B: population (batched ≤50 tcgplayer_ids) ----
  if (opts.populationEnabled) {
    const ids = (db.prepare("SELECT DISTINCT tcgplayer_id AS t FROM card WHERE tcgplayer_id IS NOT NULL ORDER BY t").all() as { t: number }[]).map((r) => r.t);
    const cardByTid = new Map<number, string[]>();
    for (const r of db.prepare("SELECT id, tcgplayer_id AS t FROM card WHERE tcgplayer_id IS NOT NULL").all() as { id: string; t: number }[]) {
      (cardByTid.get(r.t) ?? cardByTid.set(r.t, []).get(r.t)!).push(r.id);
    }
    for (let i = 0; i < ids.length; i += 50) {
      const batch = ids.slice(i, i + 50);
      const key = "pop:" + batch[0];
      if (ledger.popBatchesDone.has(key)) continue;
      let rows: PopulationRow[];
      try { rows = await client.getPopulation(batch); }
      catch (e) { if (isStopError(e)) return { ...sum, stoppedEarly: true, stopReason: (e as Error).message }; throw e; }
      const write = db.transaction((rs: PopulationRow[]) => {
        for (const r of rs) for (const cid of cardByTid.get(r.tcgPlayerId) ?? []) {
          insPop.run(cid, r.grader, r.grade, r.count, r.gemRate, r.totalPopulation, opts.asOf); sum.popRows++;
        }
      });
      write(rows);
      ledger.markPopBatch(key);
    }
  }
  return sum;
}
