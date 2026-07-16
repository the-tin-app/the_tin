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
    db.prepare("INSERT INTO price_by_condition VALUES (?,?,?,?)").run("c1", "Damaged", 7.66, "2026-07-07");
    expect(db.prepare("SELECT raw_usd FROM price_history_cond").pluck().get()).toBe(10.45);
    expect(db.prepare("SELECT usd FROM price_by_condition").pluck().get()).toBe(7.66);
  });
});
