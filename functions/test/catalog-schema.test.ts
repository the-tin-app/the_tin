import { describe, it, expect } from "vitest";
import Database from "better-sqlite3";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildCatalog } from "../src/pipeline/catalog";

function emptyInput() {
  return { sets: [], cardsBySet: new Map(), prices: new Map(), scenes: [],
    asOf: "2026-07-07", dexByCard: new Map(), pokemonNames: new Map() };
}

describe("catalog schema", () => {
  it("includes population and graded_history tables", () => {
    const out = join(tmpdir(), `cat-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog(emptyInput(), out);
    const db = new Database(out);
    db.pragma("foreign_keys = OFF");
    const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r: any) => r.name);
    expect(names).toContain("population");
    expect(names).toContain("graded_history");
    // shape sanity: insert one row each, idempotent PK
    db.prepare("INSERT INTO population VALUES (?,?,?,?,?,?,?)").run("c1", "PSA", "g10", 2500, 20.7, 12075, "2026-07-07");
    db.prepare("INSERT INTO graded_history VALUES (?,?,?,?)").run("c1", "psa10", "2026-07-01", 450);
    expect(db.prepare("SELECT count INTEGER FROM population").pluck().get()).toBe(2500);
  });

  it("price_latest has a column for every integer PSA grade", () => {
    const out = join(tmpdir(), `cat-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog(emptyInput(), out);
    const db = new Database(out);
    const cols = db.prepare("SELECT name FROM pragma_table_info('price_latest')").all().map((r: any) => r.name);
    for (let g = 1; g <= 10; g++) expect(cols).toContain(`psa${g}`);
  });

  it("includes price_history_cond and price_by_condition tables (all ungraded conditions)", () => {
    const out = join(tmpdir(), `cat-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog(emptyInput(), out);
    const db = new Database(out);
    db.pragma("foreign_keys = OFF");
    const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r: any) => r.name);
    expect(names).toContain("price_history_cond");
    expect(names).toContain("price_by_condition");
    // shape sanity: insert one row each, idempotent PK
    db.prepare("INSERT INTO price_history_cond VALUES (?,?,?,?)").run("c1", "Lightly Played", "2026-07-01", 10.45);
    db.prepare("INSERT INTO price_by_condition VALUES (?,?,?,?,?)").run("c1", "Damaged", 7.66, null, "2026-07-07");
    expect(db.prepare("SELECT raw_usd FROM price_history_cond").pluck().get()).toBe(10.45);
    expect(db.prepare("SELECT usd FROM price_by_condition").pluck().get()).toBe(7.66);
  });

  it("price_latest carries liquidity columns; graded_sales table exists", () => {
    const out = join(tmpdir(), `cat-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog(emptyInput(), out);
    const db = new Database(out);
    db.pragma("foreign_keys = OFF");
    const cols = db.prepare("SELECT name FROM pragma_table_info('price_latest')").all().map((r: any) => r.name);
    expect(cols).toContain("sellers");
    expect(cols).toContain("listings");
    // shape sanity: verbatim grade keys, idempotent PK
    db.prepare("INSERT INTO graded_sales VALUES (?,?,?,?,?)").run("c1", "psa10", 14, "high", "2026-07-19");
    db.prepare("INSERT OR REPLACE INTO graded_sales VALUES (?,?,?,?,?)").run("c1", "psa10", 15, "high", "2026-07-19");
    expect(db.prepare("SELECT sales_count FROM graded_sales").pluck().get()).toBe(15);
  });

  /// The FX rate has to travel WITH the artifact that used it: a converted Japanese price the app
  /// can't footnote with its rate and date is a price claiming to be something it isn't. Key/value
  /// on purpose — a new artifact-level fact must never mean another schema migration on a 230 MB
  /// file every device re-downloads.
  it("carries artifact meta, and tolerates having none", () => {
    const bare = join(tmpdir(), `cat-meta-none-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog(emptyInput(), bare);
    // An English-only build writes no meta at all, and the app must read that as "no rate", not
    // as a missing table.
    expect(new Database(bare).prepare("SELECT count(*) FROM meta").pluck().get()).toBe(0);

    const out = join(tmpdir(), `cat-meta-${process.pid}-${Math.round(performance.now())}.sqlite`);
    buildCatalog({ ...emptyInput(), meta: { fx_eur_usd: "1.138", fx_as_of: "2026-07-29" } }, out);
    const rows = new Database(out).prepare("SELECT key, value FROM meta ORDER BY key").all();
    expect(rows).toEqual([
      { key: "fx_as_of", value: "2026-07-29" },
      { key: "fx_eur_usd", value: "1.138" },
    ]);
  });
});
