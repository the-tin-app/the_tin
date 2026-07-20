// functions/test/overnight-sweep-core.test.ts
import { describe, it, expect } from "vitest";
import Database from "better-sqlite3";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runOvernightSweep, OvernightLedger } from "../src/pipeline/overnight-sweep-core";

function freshDb() {
  const out = join(tmpdir(), `sw-${process.pid}-${Math.round(performance.now())}-${Math.random()}.sqlite`);
  const db = new Database(out);
  db.exec(`
    CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, tcgplayer_id INTEGER);
    CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL,
      psa1 REAL, psa2 REAL, psa3 REAL, psa4 REAL, psa5 REAL, psa6 REAL,
      psa7 REAL, psa8 REAL, psa9 REAL, psa10 REAL, as_of TEXT NOT NULL);
    CREATE TABLE price_history(card_id TEXT, date TEXT, raw_usd REAL NOT NULL, PRIMARY KEY(card_id,date));
  `);
  // NOTE: price_history_cond / price_by_condition intentionally NOT predefined here — the
  // sweep's own IF-NOT-EXISTS DDL must create them.
  db.prepare("INSERT INTO card VALUES ('base-4','base','4','Charizard',111)").run();
  db.prepare("INSERT INTO price_latest VALUES ('base-4', 100, 90, NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'2026-07-01')").run();
  return db;
}
function ledger(): OvernightLedger {
  const setsDone = new Set<string>(), popBatchesDone = new Set<string>();
  return { setsDone, popBatchesDone, markSet: (id) => setsDone.add(id), markPopBatch: (k) => popBatchesDone.add(k) };
}
const pricesRaw = {
  primaryPrinting: "Holofoil",
  low: 77,
  variants: {
    Holofoil: {
      "Near Mint": { price: 95 },
      "Lightly Played": { price: 80 },
      "Moderately Played": { price: 60 },
    },
    "Reverse Holofoil": {
      "Near Mint": { price: 140 },
    },
  },
};
// Nested-conditions shape: exercises both the existing NM-only price_history path (via
// parseWeeklyHistory, which prefers "Near Mint") AND the new all-conditions path.
const conditionPriceHistory = {
  conditions: {
    "Near Mint": { history: [{ date: "2026-07-01", market: 90 }, { date: "2026-07-08", market: 95 }] },
    "Lightly Played": { history: [{ date: "2026-07-01", market: 75 }] },
    "Heavily Played": { history: [] }, // 0 points → must not write any rows
  },
};
const client = {
  getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
    priceHistory: conditionPriceHistory,
    pricesRaw, gradedLatest: { psa10: 450, psa8: 33, cgc10: 99 }, gradedSeries: [], ebayRaw: {} }]),
  getPopulation: async () => ([{ tcgPlayerId: 111, grader: "PSA", grade: "g10", count: 5, gemRate: 100, totalPopulation: 5 }]),
};
const opts = { populationEnabled: true, asOf: "2026-07-08" };
const never = () => false;

describe("runOvernightSweep", () => {
  it("writes history + graded (preserving raw) + population, idempotently", async () => {
    const db = freshDb();
    const s = await runOvernightSweep(db as any, client as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(s.historyRows).toBe(2);
    const row = db.prepare("SELECT raw_usd, raw_eur, psa8, psa10 FROM price_latest WHERE card_id='base-4'").get() as any;
    expect(row).toEqual({ raw_usd: 100, raw_eur: 90, psa8: 33, psa10: 450 }); // raw preserved, all PSA grades added (cgc dropped)
    expect(db.prepare("SELECT count FROM population WHERE card_id='base-4' AND grade='g10'").pluck().get()).toBe(5);
    // idempotent re-run of the same set (fresh ledger) does not duplicate history
    await runOvernightSweep(db as any, client as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(db.prepare("SELECT COUNT(*) FROM price_history").pluck().get()).toBe(2);
  });

  it("always writes gradedSeries to graded_history — no opt-in gate (2026-07-19: the single-card probe wrongly latched it off for every card, every night)", async () => {
    const db = freshDb();
    const c = { ...client, getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
        priceHistory: [], pricesRaw: null, gradedLatest: {},
        gradedSeries: [{ grade: "psa10", date: "2026-07-01", usd: 400 }, { grade: "psa9", date: "2026-07-01", usd: 200 }],
        ebayRaw: {} }]) };
    await runOvernightSweep(db as any, c as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(db.prepare("SELECT COUNT(*) FROM graded_history").pluck().get()).toBe(2);
    expect(db.prepare("SELECT usd FROM graded_history WHERE grade='psa10'").pluck().get()).toBe(400);
  });

  it("writes ALL ungraded conditions to price_history_cond + price_by_condition (parallel tables)", async () => {
    const db = freshDb();
    const s = await runOvernightSweep(db as any, client as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    // 2 Near Mint points + 1 Lightly Played point = 3; Heavily Played (0 points) contributes none
    expect(s.condHistoryRows).toBe(3);
    expect(s.byCondRows).toBe(3); // Near Mint, Lightly Played, Moderately Played from pricesRaw.variants
    // ALL printings (not just primaryPrinting) land in price_by_variant, one NM price each.
    expect(s.byVariantRows).toBe(2); // Holofoil + Reverse Holofoil
    expect(db.prepare("SELECT printing, usd FROM price_by_variant WHERE card_id='base-4' ORDER BY printing").all())
      .toEqual([{ printing: "Holofoil", usd: 95 }, { printing: "Reverse Holofoil", usd: 140 }]);
    const histRows = db.prepare(
      "SELECT condition, date, raw_usd FROM price_history_cond WHERE card_id='base-4' ORDER BY condition, date",
    ).all();
    expect(histRows).toEqual([
      { condition: "Lightly Played", date: "2026-07-01", raw_usd: 75 },
      { condition: "Near Mint", date: "2026-07-01", raw_usd: 90 },
      { condition: "Near Mint", date: "2026-07-08", raw_usd: 95 },
    ]);
    const byCond = db.prepare(
      "SELECT condition, usd, as_of FROM price_by_condition WHERE card_id='base-4' ORDER BY condition",
    ).all();
    expect(byCond).toEqual([
      { condition: "Lightly Played", usd: 80, as_of: "2026-07-08" },
      { condition: "Moderately Played", usd: 60, as_of: "2026-07-08" },
      { condition: "Near Mint", usd: 95, as_of: "2026-07-08" },
    ]);
    // untouched: NM-only legacy tables preserved exactly as before
    expect(s.historyRows).toBe(2);
    const nmRow = db.prepare("SELECT raw_usd FROM price_latest WHERE card_id='base-4'").get() as any;
    expect(nmRow.raw_usd).toBe(100); // price_latest NM raw_usd untouched by condition writes
    // idempotent re-run does not duplicate condition rows
    await runOvernightSweep(db as any, client as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(db.prepare("SELECT COUNT(*) FROM price_history_cond").pluck().get()).toBe(3);
    expect(db.prepare("SELECT COUNT(*) FROM price_by_condition").pluck().get()).toBe(3);
  });

  it("writes the full printing×condition matrix to price_matrix", async () => {
    const db = freshDb();
    const matrixPricesRaw = {
      primaryPrinting: "Holofoil",
      variants: {
        "Holofoil": { "Near Mint": { price: 10 }, "Lightly Played": { price: 8 } },
        "Reverse Holofoil": { "Near Mint": { price: 12 } },
      },
    };
    const c = { ...client, getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
      priceHistory: [], pricesRaw: matrixPricesRaw, gradedLatest: {}, gradedSeries: [], ebayRaw: {} }]) };
    const s = await runOvernightSweep(db as any, c as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    const rows = db.prepare(
      "SELECT printing, condition, usd FROM price_matrix WHERE card_id = 'base-4' ORDER BY printing, condition",
    ).all();
    expect(rows).toEqual([
      { printing: "Holofoil", condition: "Lightly Played", usd: 8 },
      { printing: "Holofoil", condition: "Near Mint", usd: 10 },
      { printing: "Reverse Holofoil", condition: "Near Mint", usd: 12 },
    ]);
    expect(s.matrixRows).toBe(3);
  });

  it("skips done sets and stops gracefully on a stop error", async () => {
    const db = freshDb();
    const l = ledger(); l.setsDone.add("base");
    const throwing = { ...client, getPopulation: async () => { throw new Error("PPT 403 for population"); } };
    const s = await runOvernightSweep(db as any, throwing as any, [{ setId: "base", pptName: "Base" }], l,
      opts, (e) => /PPT 403/.test((e as Error).message));
    expect(s.setsDone).toBe(0);          // set skipped (already done)
    expect(s.stoppedEarly).toBe(true);   // population 403 → graceful stop
    expect(s.stopReason).toMatch(/403/);
  });

  it("does not write a phantom all-null price_latest row when gradedLatest has no non-null values", async () => {
    const db = freshDb();
    const allNull = { ...client, getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
      priceHistory: [], gradedLatest: { psa10: null }, gradedSeries: [], ebayRaw: {} }]) };
    const before = db.prepare("SELECT raw_usd, raw_eur, psa1, psa2, psa3, psa4, psa5, psa6, psa7, psa8, psa9, psa10, as_of FROM price_latest WHERE card_id='base-4'").get();
    const s = await runOvernightSweep(db as any, allNull as any, [{ setId: "base", pptName: "Base" }], ledger(),
      { ...opts, populationEnabled: false }, never);
    expect(s.gradedRows).toBe(0);
    const after = db.prepare("SELECT raw_usd, raw_eur, psa1, psa2, psa3, psa4, psa5, psa6, psa7, psa8, psa9, psa10, as_of FROM price_latest WHERE card_id='base-4'").get();
    expect(after).toEqual(before); // no as_of bump, no phantom write
  });

  it("does not write a phantom price_latest row when gradedLatest has ONLY non-psa grades", async () => {
    const db = freshDb();
    const nonPsaOnly = { ...client, getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
      priceHistory: [], gradedLatest: { cgc10: 30 }, gradedSeries: [], ebayRaw: {} }]) };
    const before = db.prepare("SELECT raw_usd, raw_eur, psa1, psa2, psa3, psa4, psa5, psa6, psa7, psa8, psa9, psa10, as_of FROM price_latest WHERE card_id='base-4'").get();
    const s = await runOvernightSweep(db as any, nonPsaOnly as any, [{ setId: "base", pptName: "Base" }], ledger(),
      { ...opts, populationEnabled: false }, never);
    expect(s.gradedRows).toBe(0);
    const after = db.prepare("SELECT raw_usd, raw_eur, psa1, psa2, psa3, psa4, psa5, psa6, psa7, psa8, psa9, psa10, as_of FROM price_latest WHERE card_id='base-4'").get();
    expect(after).toEqual(before); // cgc10 alone must not create a phantom all-psa-null row
  });

  it("captures liquidity into price_latest and sales counts into graded_sales (ALTER guard for old DBs)", async () => {
    const db = freshDb();
    const c = { ...client, getSetEnrichment: async () => ([{ tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
      priceHistory: [], pricesRaw: { ...pricesRaw, sellers: 7, listings: 31 }, gradedLatest: {},
      gradedSeries: [],
      ebayRaw: { salesByGrade: {
        psa10: { count: 14, medianPrice: 450, smartMarketPrice: { price: 460, confidence: "high" } },
        cgc9: { count: 2, medianPrice: 90 },
      } } }]) };
    const s = await runOvernightSweep(db as any, c as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(s.liquidityRows).toBe(1);
    expect(s.gradedSalesRows).toBe(2);
    const row = db.prepare("SELECT raw_usd, sellers, listings FROM price_latest WHERE card_id='base-4'").get() as any;
    expect(row).toEqual({ raw_usd: 100, sellers: 7, listings: 31 }); // raw preserved
    expect(db.prepare("SELECT grade, sales_count, confidence FROM graded_sales ORDER BY grade").all()).toEqual([
      { grade: "cgc9", sales_count: 2, confidence: null },
      { grade: "psa10", sales_count: 14, confidence: "high" },
    ]);
  });

  it("no liquidity fields → no phantom write; empty ebay → no graded_sales rows", async () => {
    const db = freshDb();
    // pricesRaw carries `low` (for the low_usd test below), so this "no liquidity fields" case
    // needs its own pricesRaw with sellers/listings/low all absent.
    const pricesRawNoLiquidity = { primaryPrinting: pricesRaw.primaryPrinting, variants: pricesRaw.variants };
    const c = { ...client, getSetEnrichment: async () => {
      const [row] = await client.getSetEnrichment();
      return [{ ...row, pricesRaw: pricesRawNoLiquidity }];
    } };
    const s = await runOvernightSweep(db as any, c as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(s.liquidityRows).toBe(0);
    expect(s.gradedSalesRows).toBe(0);
    const row = db.prepare("SELECT sellers, listings, low_usd FROM price_latest WHERE card_id='base-4'").get() as any;
    expect(row).toEqual({ sellers: null, listings: null, low_usd: null });
    expect(db.prepare("SELECT COUNT(*) FROM graded_sales").pluck().get()).toBe(0);
  });

  it("writes prices.low into price_latest.low_usd", async () => {
    const db = freshDb();
    const s = await runOvernightSweep(db as any, client as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(s.liquidityRows).toBeGreaterThan(0);
    const low = db.prepare("SELECT low_usd FROM price_latest WHERE card_id='base-4'").pluck().get();
    expect(low).toBe(77);
  });

  it("rolls up per-condition volume into price_by_condition.sales_count", async () => {
    const db = freshDb();
    const c = { ...client, getSetEnrichment: async () => ([{
      tcgPlayerId: 111, cardNumber: "4", name: "Charizard",
      priceHistory: { conditions: {
        "Near Mint": { history: [
          { date: "2026-07-02T00:00:00Z", market: 100, volume: 4 },
          { date: "2026-06-20T00:00:00Z", market: 100, volume: 3 },
          { date: "2026-01-01T00:00:00Z", market: 90,  volume: 50 }, // >90d before asOf 2026-07-08
        ] },
        "Damaged": { history: [{ date: "2026-07-01T00:00:00Z", market: 1, volume: 0 }] }, // 0 → no row update
      } },
      pricesRaw, gradedLatest: {}, gradedSeries: [], ebayRaw: {},
    }]) };
    const s = await runOvernightSweep(db as any, c as any, [{ setId: "base", pptName: "Base" }], ledger(), opts, never);
    expect(s.condSalesRows).toBe(1);
    const nm = db.prepare("SELECT sales_count FROM price_by_condition WHERE card_id='base-4' AND condition='Near Mint'").pluck().get();
    expect(nm).toBe(7);
  });
});
