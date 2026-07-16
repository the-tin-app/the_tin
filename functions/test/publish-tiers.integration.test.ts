import { describe, it, expect, afterEach } from "vitest";
import Database from "better-sqlite3";
import { existsSync, rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { splitTiers } from "../scripts/publish-tiers";

// Real-data regression fixture: the enriched sqlite from today's validated Business-tier run.
// Absent in CI (gitignored, commercial data) → the whole suite is skipped, not failed.
const REAL_DB = join(__dirname, "../.seed-output/catalog-v8.sqlite");
const suite = existsSync(REAL_DB) ? describe : describe.skip;

function rowCount(db: Database.Database, name: string): number {
  return (db.prepare(`SELECT COUNT(*) AS n FROM "${name}"`).get() as { n: number }).n;
}

suite("splitTiers on real v8 catalog", () => {
  let outDir: string;
  afterEach(() => { if (outDir) rmSync(outDir, { recursive: true, force: true }); });

  it("produces tiers whose row counts match the validation-doc ranges", () => {
    outDir = mkdtempSync(join(tmpdir(), "tiers-int-"));
    const { casualPath, averagePath, expertPath } = splitTiers(REAL_DB, outDir);

    const expert = new Database(expertPath, { readonly: true });
    // From docs/ppt-business-pipeline-validation.md §3 (deep history present in expert only).
    expect(rowCount(expert, "price_history_cond")).toBeGreaterThan(2_000_000);
    expect(rowCount(expert, "graded_history")).toBeGreaterThan(300_000);
    expert.close();

    const average = new Database(averagePath, { readonly: true });
    expect(rowCount(average, "price_history")).toBeGreaterThan(300_000);   // ~384,725 weekly rows
    expect(() => rowCount(average, "price_history_cond")).toThrow();       // dropped
    average.close();

    const casual = new Database(casualPath, { readonly: true });
    expect(rowCount(casual, "price_history")).toBe(0);                     // emptied
    expect(rowCount(casual, "price_latest")).toBeGreaterThan(18_000);      // ~18,553 raw_usd
    casual.close();
  });
});
