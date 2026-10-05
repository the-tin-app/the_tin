/**
 * Re-run the price-delta computation against PRESERVED artifacts and report what the sanity
 * rules change — validation on copies, never a served catalog dir.
 *
 *   npx tsx scripts/validate-deltas.ts <new expert .sqlite[.gz]> [--1d <gz>] [--7d <gz>] [--30d <gz>]
 *
 * The new artifact already carries the price_delta its nightly published (the "before"). This
 * copies it to the OS tempdir, recomputes price_delta with today's computePriceDeltasFrom against
 * the same lookback artifacts (the "after"), and prints, per window: rows dropped by kind, the
 * garbage bands before/after, a check that every KEPT row's value is unchanged, the named
 * regression cards, and the Market 1M list exactly as the app would render it. Inputs are only read.
 */
import Database from "better-sqlite3";
import { copyFileSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computePriceDeltasFrom, DeltaLookback } from "./publish-tiers";

const NAMED = ["dp4-8", "ex11-112", "sm9-14", "sv07-102", "pl3-142", "ex9-35", "ecard2-53"];
const COLS = ["pct_1d", "pct_7d", "pct_30d"] as const;
// The app's Market list: Movers.marketFloorUsd and Movers.implausiblePct (ios/.../Movers.swift).
const MARKET_FLOOR_USD = 5, IMPLAUSIBLE = 5.0;

type Row = { card_id: string; kind: string; key: string; pct_1d: number | null; pct_7d: number | null; pct_30d: number | null };

function main() {
  const args = process.argv.slice(2);
  const newPath = args[0];
  if (!newPath) throw new Error("usage: validate-deltas.ts <new expert .sqlite[.gz]> [--1d gz] [--7d gz] [--30d gz]");
  const lookbacks: DeltaLookback[] = [];
  for (const [flag, col] of [["--1d", "pct_1d"], ["--7d", "pct_7d"], ["--30d", "pct_30d"]] as const) {
    const i = args.indexOf(flag);
    if (i > 0 && args[i + 1]) lookbacks.push({ col, gzPath: args[i + 1] });
  }
  const work = join(tmpdir(), `validate-deltas-${process.pid}.sqlite`);
  try {
    if (newPath.endsWith(".gz")) writeFileSync(work, gunzipSync(readFileSync(newPath)));
    else copyFileSync(newPath, work);

    const read = () => {
      const d = new Database(work, { readonly: true });
      const rows = d.prepare("SELECT card_id, kind, key, pct_1d, pct_7d, pct_30d FROM price_delta").all() as Row[];
      d.close();
      return rows;
    };
    const before = read();
    computePriceDeltasFrom(work, lookbacks);
    const after = read();
    const key = (r: Row) => `${r.card_id}\u0000${r.kind}\u0000${r.key}`;
    const afterBy = new Map(after.map((r) => [key(r), r]));
    const beforeBy = new Map(before.map((r) => [key(r), r]));

    for (const { col } of lookbacks) {
      console.log(`\n=== ${col} vs ${lookbacks.find((l) => l.col === col)!.gzPath} ===`);
      console.log("kind        rows before → after (dropped)   |pct|>1  before→after   >3   >5");
      const kinds = [...new Set(before.map((r) => r.kind))].sort();
      for (const kind of kinds) {
        const b = before.filter((r) => r.kind === kind && r[col] != null);
        const a = after.filter((r) => r.kind === kind && r[col] != null);
        const band = (rs: Row[], t: number) => rs.filter((r) => Math.abs(r[col]!) > t).length;
        console.log(`${kind.padEnd(11)} ${String(b.length).padStart(6)} → ${String(a.length).padStart(6)} (${String(b.length - a.length).padStart(5)})`
          + `   ${String(band(b, 1)).padStart(5)}→${String(band(a, 1)).padEnd(5)} ${band(b, 3)}→${band(a, 3)}  ${band(b, 5)}→${band(a, 5)}`);
      }
      // A kept row must carry exactly the value it had: the rules may only remove, never alter.
      let changed = 0, appeared = 0;
      for (const b of before) {
        if (b[col] == null) continue;
        const a = afterBy.get(key(b));
        if (a?.[col] != null && Math.abs(a[col]! - b[col]!) > 1e-9) changed++;
      }
      for (const a of after) if (a[col] != null && beforeBy.get(key(a))?.[col] == null) appeared++;
      console.log(`kept rows whose value changed: ${changed}   rows that appeared from nothing: ${appeared}   (both must be 0)`);
    }

    console.log("\n=== named regression cards (pct_30d, before → after) ===");
    for (const id of NAMED) {
      const rows = before.filter((r) => r.card_id === id && r.pct_30d != null);
      for (const b of rows) {
        const a = afterBy.get(key(b))?.pct_30d;
        const pct = (v: number | null | undefined) => (v == null ? "—" : `${(v * 100).toFixed(1)}%`);
        console.log(`${id.padEnd(10)} ${b.kind.padEnd(9)} ${b.key.padEnd(34)} ${pct(b.pct_30d).padStart(10)} → ${pct(a)}`);
      }
    }

    // CatalogStore.topMovers for the 1M window, verbatim in shape: per-printing first, raw only for
    // cards with no printing deltas, $5 floor, ≤ +500%, one row per card (its biggest mover).
    const d = new Database(work, { readonly: true });
    const market = d.prepare(`
      SELECT card_id, printing, pct, usd FROM (
        SELECT d.card_id AS card_id, d.key AS printing, d.pct_30d AS pct, v.usd AS usd
        FROM price_delta d JOIN price_by_variant v ON v.card_id = d.card_id AND v.printing = d.key
        WHERE d.kind = 'printing' AND d.pct_30d IS NOT NULL AND v.usd >= ? AND ABS(d.pct_30d) <= ?
        UNION ALL
        SELECT d.card_id, NULL, d.pct_30d, p.raw_usd
        FROM price_delta d JOIN price_latest p ON p.card_id = d.card_id
        WHERE d.kind = 'raw' AND d.pct_30d IS NOT NULL AND p.raw_usd >= ? AND ABS(d.pct_30d) <= ?
          AND NOT EXISTS (SELECT 1 FROM price_delta pd WHERE pd.card_id = d.card_id AND pd.kind = 'printing'))
      ORDER BY ABS(pct) DESC LIMIT 300`).all(MARKET_FLOOR_USD, IMPLAUSIBLE, MARKET_FLOOR_USD, IMPLAUSIBLE) as
      { card_id: string; printing: string | null; pct: number; usd: number }[];
    const seen = new Set<string>();
    const name = d.prepare("SELECT name, set_id, number FROM card WHERE id = ?");
    console.log("\n=== Market → 1M after the fix, as the app lists it (top 25) ===");
    let n = 0;
    for (const m of market) {
      if (seen.has(m.card_id) || n >= 25) continue;
      seen.add(m.card_id); n++;
      const c = name.get(m.card_id) as { name: string; set_id: string; number: string } | undefined;
      console.log(`${String(n).padStart(2)}. ${(c?.name ?? m.card_id).padEnd(26)} ${`${c?.set_id ?? ""} #${c?.number ?? ""}`.padEnd(14)} `
        + `$${m.usd.toFixed(2).padStart(9)}  ${(m.printing ?? "raw").padEnd(28)} ${m.pct >= 0 ? "+" : ""}${(m.pct * 100).toFixed(1)}%`);
    }
    d.close();
  } finally {
    rmSync(work, { force: true });
  }
}

main();
