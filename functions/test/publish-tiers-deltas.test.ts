import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, utimesSync, readFileSync, existsSync } from "node:fs";
import { gzipSync, gunzipSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computePriceDeltas, publishTiers, pruneOldArtifacts, NasManifest } from "../scripts/publish-tiers";
import { StoragePort } from "../src/pipeline/publish";

const DAY_MS = 86_400_000;
const NOW = new Date("2026-07-18T07:00:00Z");

/** Schema shared by the "new" source DB and old snapshot artifacts. */
const PRICE_SCHEMA = `
  CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL,
    psa1 REAL, psa2 REAL, psa3 REAL, psa4 REAL, psa5 REAL, psa6 REAL,
    psa7 REAL, psa8 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
  CREATE TABLE price_by_condition(card_id TEXT, condition TEXT, usd REAL, as_of TEXT,
    PRIMARY KEY(card_id, condition));
  CREATE TABLE price_by_variant(card_id TEXT, printing TEXT, usd REAL, as_of TEXT,
    PRIMARY KEY(card_id, printing));
`;

interface SnapshotPrices {
  raw?: number | null; psa10?: number | null;
  nm?: number | null; holo?: number | null;
}

function insertPrices(db: Database.Database, p: SnapshotPrices) {
  db.prepare(`INSERT INTO price_latest(card_id, raw_usd, psa10, as_of)
              VALUES ('c1', ?, ?, '2026-07-18')`).run(p.raw ?? null, p.psa10 ?? null);
  if (p.nm != null)
    db.prepare(`INSERT INTO price_by_condition VALUES ('c1', 'Near Mint', ?, '2026-07-18')`).run(p.nm);
  if (p.holo != null)
    db.prepare(`INSERT INTO price_by_variant VALUES ('c1', 'Holofoil', ?, '2026-07-18')`).run(p.holo);
}

/** Write a gzipped old snapshot `expert-v<n>.sqlite.gz` into catalogDir, mtime `ageDays` ago. */
function makeSnapshot(catalogDir: string, version: number, ageDays: number, p: SnapshotPrices) {
  const raw = join(catalogDir, `snapshot-${version}.sqlite`);
  const db = new Database(raw);
  db.exec(PRICE_SCHEMA);
  insertPrices(db, p);
  db.close();
  const gzPath = join(catalogDir, `expert-v${version}.sqlite.gz`);
  writeFileSync(gzPath, gzipSync(readFileSync(raw)));
  rmSync(raw);
  const mtime = new Date(NOW.getTime() - ageDays * DAY_MS);
  utimesSync(gzPath, mtime, mtime);
}

function makeSource(dir: string, p: SnapshotPrices): string {
  const path = join(dir, "source.sqlite");
  const db = new Database(path);
  db.exec(PRICE_SCHEMA);
  insertPrices(db, p);
  db.close();
  return path;
}

function deltaRows(sourcePath: string) {
  const db = new Database(sourcePath, { readonly: true });
  const rows = db.prepare("SELECT * FROM price_delta ORDER BY kind, key").all() as {
    card_id: string; kind: string; key: string;
    pct_1d: number | null; pct_7d: number | null; pct_30d: number | null;
  }[];
  db.close();
  return rows;
}

describe("computePriceDeltas", () => {
  let dir: string, catalogDir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "deltas-"));
    catalogDir = join(dir, "catalog");
    mkdirSync(catalogDir);
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("computes 1d deltas across all four dimensions", () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0, psa10: 100, nm: 1.6, holo: 4.0 });
    const src = makeSource(dir, { raw: 3.0, psa10: 90, nm: 2.0, holo: 4.0 });
    computePriceDeltas(src, catalogDir, NOW);
    const rows = deltaRows(src);
    const by = (kind: string, key: string) => rows.find(r => r.kind === kind && r.key === key);
    expect(by("raw", "")?.pct_1d).toBeCloseTo(0.5);          // (3-2)/2
    expect(by("psa", "10")?.pct_1d).toBeCloseTo(-0.1);       // (90-100)/100
    expect(by("condition", "Near Mint")?.pct_1d).toBeCloseTo(0.25);
    expect(by("printing", "Holofoil")?.pct_1d).toBeCloseTo(0.0);
    expect(by("raw", "")?.pct_7d).toBeNull();                // no 7d artifact
  });

  it("skips artifacts outside a lookback window", () => {
    makeSnapshot(catalogDir, 5, 4, { raw: 2.0 });            // 4 days: outside 1d (0.5-3) AND 7d (5-10)
    const src = makeSource(dir, { raw: 3.0 });
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src)).toHaveLength(0);                  // table exists, empty
  });

  it("picks the artifact closest to the target age", () => {
    makeSnapshot(catalogDir, 5, 9.5, { raw: 1.0 });          // in 7d window, far from 7
    makeSnapshot(catalogDir, 6, 6.5, { raw: 2.0 });          // in 7d window, closest to 7
    const src = makeSource(dir, { raw: 3.0 });
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).find(r => r.kind === "raw")?.pct_7d).toBeCloseTo(0.5); // vs 2.0, not 1.0
  });

  it("writes no row when the old price is missing or non-positive", () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 0, psa10: null, nm: null, holo: null });
    const src = makeSource(dir, { raw: 3.0, psa10: 90 });
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src)).toHaveLength(0);
  });

  it("creates an empty table when no artifacts exist, and re-runs idempotently", () => {
    const src = makeSource(dir, { raw: 3.0 });
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src)).toHaveLength(0);
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0 });
    computePriceDeltas(src, catalogDir, NOW);               // second run must not throw or dupe
    computePriceDeltas(src, catalogDir, NOW);
    const raws = deltaRows(src).filter(r => r.kind === "raw");
    expect(raws).toHaveLength(1);
    expect(raws[0].pct_1d).toBeCloseTo(0.5);
  });
});

class MemStore implements StoragePort {
  files = new Map<string, Buffer>();
  async save(path: string, data: Buffer) { this.files.set(path, Buffer.from(data)); }
}

function openGz(path: string): Database.Database {
  const raw = path.replace(/\.gz$/, ".unzipped");
  writeFileSync(raw, gunzipSync(readFileSync(path)));
  return new Database(raw, { readonly: true });
}

describe("publishTiers with deltas", () => {
  let dir: string, nasDir: string, catalogDir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "deltas-pub-"));
    nasDir = join(dir, "nas");
    catalogDir = join(nasDir, "catalog");
    mkdirSync(catalogDir, { recursive: true });
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("average+expert carry populated price_delta; casual has the table EMPTY", async () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0 });
    const src = makeSource(dir, { raw: 3.0 });
    const m = await publishTiers({ sourceDbPath: src, version: 8, nasDir,
      firebaseStorage: new MemStore(), now: NOW, publishToFirebase: false });
    for (const tier of ["average", "expert"] as const) {
      const db = openGz(join(catalogDir, m.tiers[tier].path));
      expect(db.prepare("SELECT COUNT(*) AS n FROM price_delta").get()).toEqual({ n: 1 });
      db.close();
    }
    const casual = openGz(join(catalogDir, m.tiers.casual.path));
    expect(casual.prepare("SELECT COUNT(*) AS n FROM price_delta").get()).toEqual({ n: 0 });
    casual.close();
  });

  it("publishes even when delta computation throws", async () => {
    const src = makeSource(dir, { raw: 3.0 });
    // Corrupt "artifact" in the 1d window: gunzip inside computePriceDeltas throws, the
    // publishTiers wrapper swallows it, and the tiers still ship (without deltas).
    const bad = join(catalogDir, "expert-v7.sqlite.gz");
    writeFileSync(bad, Buffer.from("not gzip"));
    const mtime = new Date(NOW.getTime() - DAY_MS);
    utimesSync(bad, mtime, mtime);
    const m = await publishTiers({ sourceDbPath: src, version: 8, nasDir,
      firebaseStorage: new MemStore(), now: NOW, publishToFirebase: false });
    expect(existsSync(join(catalogDir, m.tiers.expert.path))).toBe(true);
  });
});

describe("pruneOldArtifacts", () => {
  it("deletes tier files older than 45 days but never the current manifest's", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    makeSnapshot(dir, 1, 60, { raw: 1 });           // 60 days old → pruned
    makeSnapshot(dir, 2, 44, { raw: 1 });           // 44 days → kept
    makeSnapshot(dir, 3, 60, { raw: 1 });           // 60 days old BUT in manifest → kept
    const manifest = { version: 3, generatedAt: NOW.toISOString(), tiers: {
      casual: { path: "casual-v3.sqlite.gz", sha256: "", sizeBytes: 0 },
      average: { path: "average-v3.sqlite.gz", sha256: "", sizeBytes: 0 },
      expert: { path: "expert-v3.sqlite.gz", sha256: "", sizeBytes: 0 },
    } } as NasManifest;
    const deleted = pruneOldArtifacts(dir, manifest, NOW);
    expect(deleted).toEqual(["expert-v1.sqlite.gz"]);
    expect(existsSync(join(dir, "expert-v2.sqlite.gz"))).toBe(true);
    expect(existsSync(join(dir, "expert-v3.sqlite.gz"))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });
});
