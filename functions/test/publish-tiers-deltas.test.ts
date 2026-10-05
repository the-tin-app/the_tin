import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, utimesSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { gzipSync, gunzipSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computePriceDeltas, computePriceDeltasFrom, publishTiers, pruneOldArtifacts, NasManifest } from "../scripts/publish-tiers";
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
  nm?: number | null; holo?: number | null; matrix?: number | null;
  /** Which printing raw_usd quotes. Only written when the schema carries the column. */
  basis?: string | null;
}

function insertPrices(db: Database.Database, p: SnapshotPrices) {
  const hasBasis = (db.pragma("table_info(price_latest)") as { name: string }[])
    .some((c) => c.name === "raw_printing");
  if (hasBasis) {
    db.prepare(`INSERT INTO price_latest(card_id, raw_usd, psa10, raw_printing, as_of)
                VALUES ('c1', ?, ?, ?, '2026-07-18')`).run(p.raw ?? null, p.psa10 ?? null, p.basis ?? null);
  } else {
    db.prepare(`INSERT INTO price_latest(card_id, raw_usd, psa10, as_of)
                VALUES ('c1', ?, ?, '2026-07-18')`).run(p.raw ?? null, p.psa10 ?? null);
  }
  if (p.nm != null)
    db.prepare(`INSERT INTO price_by_condition VALUES ('c1', 'Near Mint', ?, '2026-07-18')`).run(p.nm);
  if (p.holo != null)
    db.prepare(`INSERT INTO price_by_variant VALUES ('c1', 'Holofoil', ?, '2026-07-18')`).run(p.holo);
  if (p.matrix != null)
    db.prepare(`INSERT INTO price_matrix VALUES ('c1', 'Holofoil', 'Near Mint', ?, '2026-07-18')`).run(p.matrix);
}

/** Pre-psa-widening artifact schema (production ≤ v13): only psa8-10 columns exist. */
const LEGACY_SCHEMA = PRICE_SCHEMA.replace(
  /psa1 REAL.*psa7 REAL,\s*/s, "");

/** Current schema: price_latest records WHICH printing raw_usd quotes. Artifacts published before
 *  this column use bare PRICE_SCHEMA, which is what every other test in this file exercises. */
const BASIS_SCHEMA = PRICE_SCHEMA.replace("raw_usd REAL,", "raw_usd REAL, raw_printing TEXT,");

/** Schema including price_matrix (Task 2) — old artifacts published before that feature use
 *  bare PRICE_SCHEMA instead, exercising the same legacy-tolerance pattern as LEGACY_SCHEMA above. */
const MATRIX_SCHEMA = PRICE_SCHEMA + `
  CREATE TABLE price_matrix(card_id TEXT, printing TEXT, condition TEXT, usd REAL, as_of TEXT,
    PRIMARY KEY(card_id, printing, condition));
`;

/** Write a gzipped old snapshot `expert-v<n>.sqlite.gz` into catalogDir, mtime `ageDays` ago. */
function makeSnapshot(catalogDir: string, version: number, ageDays: number, p: SnapshotPrices,
                      schema = PRICE_SCHEMA) {
  const raw = join(catalogDir, `snapshot-${version}.sqlite`);
  const db = new Database(raw);
  db.exec(schema);
  insertPrices(db, p);
  db.close();
  const gzPath = join(catalogDir, `expert-v${version}.sqlite.gz`);
  writeFileSync(gzPath, gzipSync(readFileSync(raw)));
  rmSync(raw);
  const mtime = new Date(NOW.getTime() - ageDays * DAY_MS);
  utimesSync(gzPath, mtime, mtime);
}

function makeSource(dir: string, p: SnapshotPrices, schema = PRICE_SCHEMA): string {
  const path = join(dir, "source.sqlite");
  const db = new Database(path);
  db.exec(schema);
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

  it("tolerates an old artifact missing psa columns (pre-widening schema)", () => {
    makeSnapshot(catalogDir, 5, 7, { raw: 2.0, psa10: 100, nm: 1.6, holo: 4.0 }, LEGACY_SCHEMA);
    makeSnapshot(catalogDir, 7, 1, { raw: 2.5 });
    const src = makeSource(dir, { raw: 3.0, psa10: 90, nm: 2.0, holo: 4.0 });
    computePriceDeltas(src, catalogDir, NOW);
    const rows = deltaRows(src);
    const by = (kind: string, key: string) => rows.find(r => r.kind === kind && r.key === key);
    expect(by("raw", "")?.pct_1d).toBeCloseTo(0.2);            // (3-2.5)/2.5 — 1d pass intact
    expect(by("raw", "")?.pct_7d).toBeCloseTo(0.5);            // (3-2)/2
    expect(by("psa", "10")?.pct_7d).toBeCloseTo(-0.1);         // psa10 exists in legacy schema
    expect(by("condition", "Near Mint")?.pct_7d).toBeCloseTo(0.25); // must run despite psa1-7 gone
    expect(by("printing", "Holofoil")?.pct_7d).toBeCloseTo(0.0);
  });

  it("computes matrix deltas keyed printing|condition", () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0, matrix: 100 }, MATRIX_SCHEMA);
    const src = makeSource(dir, { raw: 3.0, matrix: 110 }, MATRIX_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    const db = new Database(src, { readonly: true });
    const rows = db.prepare("SELECT kind, key, pct_1d FROM price_delta WHERE kind='matrix'").all();
    db.close();
    expect(rows).toEqual([{ kind: "matrix", key: "Holofoil|Near Mint", pct_1d: expect.closeTo(0.1) }]);
  });

  it("tolerates an old artifact without price_matrix (pre-feature legacy)", () => {
    // Old artifact predates the price_matrix feature entirely (bare PRICE_SCHEMA, no table) —
    // the new source DOES have price_matrix, mirroring a real rollout day.
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0 });
    const src = makeSource(dir, { raw: 3.0, matrix: 110 }, MATRIX_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    const db = new Database(src, { readonly: true });
    const rawDeltaRows = db.prepare("SELECT * FROM price_delta WHERE kind='raw'").all();
    const matrixCount = db.prepare("SELECT COUNT(*) AS n FROM price_delta WHERE kind='matrix'").get();
    db.close();
    expect(rawDeltaRows.length).toBeGreaterThan(0);
    expect(matrixCount).toEqual({ n: 0 });
  });

  it("a broken artifact kills only its own lookback", () => {
    const bad = join(catalogDir, "expert-v9.sqlite.gz");       // 1d window, gunzips to non-sqlite
    writeFileSync(bad, gzipSync(Buffer.from("not a sqlite database")));
    const mtime = new Date(NOW.getTime() - DAY_MS);
    utimesSync(bad, mtime, mtime);
    makeSnapshot(catalogDir, 5, 7, { raw: 2.0 });
    const src = makeSource(dir, { raw: 3.0 });
    computePriceDeltas(src, catalogDir, NOW);
    const raw = deltaRows(src).find(r => r.kind === "raw");
    expect(raw?.pct_1d).toBeNull();
    expect(raw?.pct_7d).toBeCloseTo(0.5);                      // 7d survived the 1d failure
  });

  // --- raw_usd's printing basis -------------------------------------------------------------
  // raw_usd quotes whichever printing had a market price that night, so the same column can mean
  // a different printing in each artifact. Diffing across that measures the spread between two
  // printings, not a price move.

  it("emits no raw delta when the printing basis flipped between artifacts", () => {
    // Yesterday the primary printing had no price, so raw_usd fell through to 1st Edition at $900;
    // tonight Unlimited is priced again at $5. Naively that reads as -99.4%.
    makeSnapshot(catalogDir, 7, 1, { raw: 900, basis: "1st Edition" }, BASIS_SCHEMA);
    const src = makeSource(dir, { raw: 5, basis: "Unlimited" }, BASIS_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).filter(r => r.kind === "raw")).toHaveLength(0);
  });

  it("emits the raw delta normally when the basis held", () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0, basis: "Unlimited" }, BASIS_SCHEMA);
    const src = makeSource(dir, { raw: 3.0, basis: "Unlimited" }, BASIS_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).find(r => r.kind === "raw")?.pct_1d).toBeCloseTo(0.5);
  });

  it("treats an unlabeled basis on both sides as a match (NULL IS NULL)", () => {
    // Cards priced off the base tcgcsv path carry no printing label. Those must keep their deltas
    // rather than silently vanishing — a plain `=` comparison would drop every one of them.
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0, basis: null }, BASIS_SCHEMA);
    const src = makeSource(dir, { raw: 3.0, basis: null }, BASIS_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).find(r => r.kind === "raw")?.pct_1d).toBeCloseTo(0.5);
  });

  it("a labeled basis and an unlabeled one do not match", () => {
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0, basis: null }, BASIS_SCHEMA);
    const src = makeSource(dir, { raw: 3.0, basis: "Unlimited" }, BASIS_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).filter(r => r.kind === "raw")).toHaveLength(0);
  });

  it("falls back to the card-id join against an artifact predating raw_printing", () => {
    // Deliberate: blacking out every raw delta until the 30d ledger ages over would gut Movers for
    // a month. 1d becomes verified after one nightly, 7d after a week, 30d after a month.
    makeSnapshot(catalogDir, 7, 1, { raw: 2.0 });                       // no raw_printing column
    const src = makeSource(dir, { raw: 3.0, basis: "Unlimited" }, BASIS_SCHEMA);
    computePriceDeltas(src, catalogDir, NOW);
    expect(deltaRows(src).find(r => r.kind === "raw")?.pct_1d).toBeCloseTo(0.5);
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

  it("publishes and leaves no leaked temp file when a 1d artifact gunzips fine but isn't a valid sqlite", async () => {
    const src = makeSource(dir, { raw: 3.0 });
    // gunzip succeeds (it's real gzip), but the decompressed bytes aren't a sqlite database, so
    // ATTACH (or the first query against it) throws inside computePriceDeltas's per-lookback block.
    const bad = join(catalogDir, "expert-v7.sqlite.gz");
    writeFileSync(bad, gzipSync(Buffer.from("not a sqlite database at all")));
    const mtime = new Date(NOW.getTime() - DAY_MS);
    utimesSync(bad, mtime, mtime);
    const m = await publishTiers({ sourceDbPath: src, version: 8, nasDir,
      firebaseStorage: new MemStore(), now: NOW, publishToFirebase: false });
    expect(existsSync(join(catalogDir, m.tiers.expert.path))).toBe(true);
    expect(readdirSync(catalogDir).some(f => f.startsWith("_delta-lookback-"))).toBe(false);
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

describe("pruneOldArtifacts — per-tier retention", () => {
  const NOW = new Date("2026-08-02T07:00:00Z");

  /** Write a zero-byte artifact and backdate its mtime by `ageDays`. */
  function artifact(dir: string, name: string, ageDays: number) {
    const p = join(dir, name);
    writeFileSync(p, "");
    const t = new Date(NOW.getTime() - ageDays * 86_400_000);
    utimesSync(p, t, t);
  }

  function manifestFor(version: number): NasManifest {
    const e = (tier: string) => ({ path: `${tier}-v${version}.sqlite.gz`, sha256: "x", sizeBytes: 1 });
    return {
      version,
      generatedAt: NOW.toISOString(),
      tiers: { casual: e("casual"), average: e("average"), expert: e("expert") },
    };
  }

  it("keeps only the 3 newest casual/average versions regardless of age", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    for (const v of [27, 28, 29, 30]) {
      artifact(dir, `casual-v${v}.sqlite.gz`, 30 - v);
      artifact(dir, `average-v${v}.sqlite.gz`, 30 - v);
    }
    const deleted = pruneOldArtifacts(dir, manifestFor(30), NOW);
    expect(deleted.sort()).toEqual(["average-v27.sqlite.gz", "casual-v27.sqlite.gz"]);
    expect(existsSync(join(dir, "casual-v28.sqlite.gz"))).toBe(true);
    expect(existsSync(join(dir, "casual-v30.sqlite.gz"))).toBe(true);
  });

  it("keeps expert artifacts by AGE, not by version count — the delta ledger", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    // 30 expert versions, one per day. All are inside the 45-day window.
    for (let i = 0; i < 30; i++) artifact(dir, `expert-v${30 - i}.sqlite.gz`, i);
    const deleted = pruneOldArtifacts(dir, manifestFor(30), NOW);
    expect(deleted).toEqual([]);
    // The 30d lookback window (25–40 days) must still have a candidate.
    expect(existsSync(join(dir, "expert-v3.sqlite.gz"))).toBe(true);
  });

  it("still deletes expert artifacts past 45 days", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    artifact(dir, "expert-v1.sqlite.gz", 46);
    artifact(dir, "expert-v29.sqlite.gz", 1);
    const deleted = pruneOldArtifacts(dir, manifestFor(30), NOW);
    expect(deleted).toEqual(["expert-v1.sqlite.gz"]);
  });

  it("never deletes a file the current manifest names", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    for (const t of ["casual", "average", "expert"]) artifact(dir, `${t}-v30.sqlite.gz`, 99);
    expect(pruneOldArtifacts(dir, manifestFor(30), NOW)).toEqual([]);
  });

  it("ignores files that are not tier artifacts", () => {
    const dir = mkdtempSync(join(tmpdir(), "prune-"));
    artifact(dir, "manifest.json", 99);
    artifact(dir, "supporters.json", 99);
    artifact(dir, "catalog-v9.sqlite.gz", 99);
    expect(pruneOldArtifacts(dir, manifestFor(30), NOW)).toEqual([]);
    expect(existsSync(join(dir, "supporters.json"))).toBe(true);
  });
});

/**
 * The four sanity rules, on the cases that put garbage on screen on 2026-10-04 (v92 vs v62).
 * Every DB here carries the full current schema, so each rule is live; the legacy-schema
 * behaviour is covered above.
 */
describe("computePriceDeltasFrom — sanity rules", () => {
  const FULL_SCHEMA = `
    CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL,
      psa1 REAL, psa2 REAL, psa3 REAL, psa4 REAL, psa5 REAL, psa6 REAL,
      psa7 REAL, psa8 REAL, psa9 REAL, psa10 REAL, raw_printing TEXT, price_source INTEGER, as_of TEXT);
    CREATE TABLE price_by_condition(card_id TEXT, condition TEXT, usd REAL, as_of TEXT, PRIMARY KEY(card_id, condition));
    CREATE TABLE price_by_variant(card_id TEXT, printing TEXT, usd REAL, as_of TEXT, PRIMARY KEY(card_id, printing));
    CREATE TABLE price_matrix(card_id TEXT, printing TEXT, condition TEXT, usd REAL, as_of TEXT,
      PRIMARY KEY(card_id, printing, condition));
    CREATE TABLE graded_sales(card_id TEXT, grade TEXT, sales_count INTEGER, confidence TEXT, as_of TEXT,
      PRIMARY KEY(card_id, grade));`;

  type Ladder = Partial<Record<"Near Mint" | "Lightly Played" | "Moderately Played" | "Heavily Played" | "Damaged", number>>;
  interface Card {
    id: string; raw?: number; rawPrinting?: string; source?: number | null;
    psa?: Record<number, { usd: number; sales: number }>;
    conditions?: Ladder;
    /** printing → its market price, and (optionally) its condition ladder in price_matrix. */
    printings?: Record<string, { usd: number; matrix?: Ladder }>;
  }

  function db(path: string, cards: Card[], schema = FULL_SCHEMA) {
    const d = new Database(path);
    d.exec(schema);
    for (const c of cards) {
      const psa = Object.fromEntries(Array.from({ length: 10 }, (_, i) => [`psa${i + 1}`, c.psa?.[i + 1]?.usd ?? null]));
      const hasSource = (d.pragma("table_info(price_latest)") as { name: string }[]).some((x) => x.name === "price_source");
      d.prepare(`INSERT INTO price_latest(card_id, raw_usd, ${Object.keys(psa).join(",")}, raw_printing${hasSource ? ", price_source" : ""}, as_of)
                 VALUES (@id, @raw, ${Object.keys(psa).map((k) => "@" + k).join(",")}, @rp${hasSource ? ", @src" : ""}, 'x')`)
        .run({ id: c.id, raw: c.raw ?? null, rp: c.rawPrinting ?? null, src: c.source ?? null, ...psa });
      for (const [g, v] of Object.entries(c.psa ?? {}))
        d.prepare("INSERT INTO graded_sales VALUES (?, ?, ?, NULL, 'x')").run(c.id, `psa${g}`, v.sales);
      for (const [cond, usd] of Object.entries(c.conditions ?? {}))
        d.prepare("INSERT INTO price_by_condition VALUES (?, ?, ?, 'x')").run(c.id, cond, usd);
      for (const [printing, v] of Object.entries(c.printings ?? {})) {
        d.prepare("INSERT INTO price_by_variant VALUES (?, ?, ?, 'x')").run(c.id, printing, v.usd);
        for (const [cond, usd] of Object.entries(v.matrix ?? {}))
          d.prepare("INSERT INTO price_matrix VALUES (?, ?, ?, ?, 'x')").run(c.id, printing, cond, usd);
      }
    }
    d.close();
  }

  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "sanity-")); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  /** Old snapshot (gzipped, as published) → new DB → deltas for the 30d column. */
  function run(oldCards: Card[], newCards: Card[], oldSchema = FULL_SCHEMA) {
    const oldRaw = join(dir, "old.sqlite");
    db(oldRaw, oldCards, oldSchema);
    const gz = join(dir, "expert-v62.sqlite.gz");
    writeFileSync(gz, gzipSync(readFileSync(oldRaw)));
    const src = join(dir, "source.sqlite");
    db(src, newCards);
    computePriceDeltasFrom(src, [{ col: "pct_30d", gzPath: gz }]);
    const rows = deltaRows(src);
    return (kind: string, key = "", card?: string) =>
      rows.find((r) => r.kind === kind && r.key === key && (!card || r.card_id === card))?.pct_30d;
  }

  const sane: Ladder = { "Near Mint": 20, "Lightly Played": 15, "Moderately Played": 9, "Heavily Played": 6, "Damaged": 4 };

  it("Sceptile: a printing whose NM sat under Damaged one night gets no printing or matrix delta", () => {
    const old = [{ id: "dp4-8", raw: 20.88, rawPrinting: "Holofoil", conditions: sane, printings: {
      "Holofoil": { usd: 20.88, matrix: { ...sane, "Near Mint": 20.88 } },
      "Reverse Holofoil": { usd: 2.97, matrix: { "Near Mint": 2.97, "Lightly Played": 18.88, "Damaged": 4.24 } } } }];
    const now = [{ id: "dp4-8", raw: 24.39, rawPrinting: "Holofoil", conditions: sane, printings: {
      "Holofoil": { usd: 24.39, matrix: { ...sane, "Near Mint": 24.39 } },
      "Reverse Holofoil": { usd: 16.48, matrix: { "Near Mint": 25, "Lightly Played": 20.52, "Damaged": 4.44 } } } }];
    const pct = run(old, now);
    expect(pct("printing", "Reverse Holofoil")).toBeUndefined();          // was +454.9%
    expect(pct("matrix", "Reverse Holofoil|Near Mint")).toBeUndefined();
    expect(pct("matrix", "Reverse Holofoil|Lightly Played")).toBeUndefined();  // the other half of the bad pair
    expect(pct("matrix", "Reverse Holofoil|Damaged")).toBeCloseTo(4.44 / 4.24 - 1); // the rest of the ladder keeps its delta
    expect(pct("printing", "Holofoil")).toBeCloseTo(24.39 / 20.88 - 1);   // the sane printing still moves
    expect(pct("raw")).toBeCloseTo(24.39 / 20.88 - 1);                    // +16.8%, matching the history
  });

  it("Kyogre Star: raw is blanked when the printing it quotes has a broken ladder, though the label matched", () => {
    const old = [{ id: "ex11-112", raw: 299.99, rawPrinting: "Holofoil",
      conditions: { "Moderately Played": 299.99, "Heavily Played": 600, "Damaged": 500 },
      printings: { "Holofoil": { usd: 299.99, matrix: { "Moderately Played": 299.99, "Heavily Played": 600, "Damaged": 500 } } } }];
    const now = [{ id: "ex11-112", raw: 1602.99, rawPrinting: "Holofoil",
      conditions: { "Moderately Played": 1602.99, "Heavily Played": 600, "Damaged": 500 },
      printings: { "Holofoil": { usd: 1602.99, matrix: { "Moderately Played": 1602.99, "Heavily Played": 600, "Damaged": 500 } } } }];
    const pct = run(old, now);
    expect(pct("raw")).toBeUndefined();                                    // was +434.3%, past the raw_printing guard
    expect(pct("printing", "Holofoil")).toBeUndefined();
    expect(pct("matrix", "Holofoil|Moderately Played")).toBeUndefined();
    expect(pct("condition", "Moderately Played")).toBeUndefined();         // the card-level ladder was broken too
  });

  it("Charizard and Meltan: a 'printing' with no condition ladder gets no printing delta", () => {
    const old = [
      { id: "sm9-14", printings: { "Miscellaneous Cards & Products": { usd: 50.64 }, "Normal": { usd: 17.27, matrix: { "Near Mint": 17.27, "Lightly Played": 15 } } } },
      { id: "sv07-102", printings: { "Stellar Crown Stamped": { usd: 1 } } },
    ];
    const now = [
      { id: "sm9-14", printings: { "Miscellaneous Cards & Products": { usd: 275 }, "Normal": { usd: 17.32, matrix: { "Near Mint": 17.32, "Lightly Played": 15 } } } },
      { id: "sv07-102", printings: { "Stellar Crown Stamped": { usd: 15.65 } } },
    ];
    const pct = run(old, now);
    expect(pct("printing", "Miscellaneous Cards & Products")).toBeUndefined();  // was +443%
    expect(pct("printing", "Stellar Crown Stamped")).toBeUndefined();           // was +1465%
    expect(pct("printing", "Normal")).toBeCloseTo(17.32 / 17.27 - 1);           // the real card: +0.3%
  });

  it("a big graded move needs another grade to move with it", () => {
    const g = (usd: number) => ({ usd, sales: 1 });
    const alone = run([{ id: "c1", psa: { 9: g(100), 10: g(300) } }], [{ id: "c1", psa: { 9: g(105), 10: g(1200) } }]);
    expect(alone("psa", "10")).toBeUndefined();                            // +300%, PSA 9 moved +5%: no witness
    expect(alone("psa", "9")).toBeCloseTo(0.05);                           // small moves need none
    rmSync(dir, { recursive: true, force: true }); dir = mkdtempSync(join(tmpdir(), "sanity-"));
    const together = run([{ id: "c1", psa: { 9: g(100), 10: g(300) } }], [{ id: "c1", psa: { 9: g(180), 10: g(1200) } }]);
    expect(together("psa", "10")).toBeCloseTo(3);                          // PSA 9 +80% vouches for it
  });

  it("a card whose PPT product changed gets no delta of any kind", () => {
    const card = (source: number, usd: number) => ({ id: "c1", raw: usd, rawPrinting: "Holofoil", source,
      conditions: { "Near Mint": usd }, printings: { "Holofoil": { usd, matrix: { "Near Mint": usd } } } });
    const moved = run([card(111, 10)], [card(222, 50)]);
    for (const [kind, key] of [["raw", ""], ["condition", "Near Mint"], ["printing", "Holofoil"], ["matrix", "Holofoil|Near Mint"]])
      expect(moved(kind, key)).toBeUndefined();
  });

  it("the same product, or an artifact from before price_source, is diffed as before", () => {
    const card = (source: number | null, usd: number) => ({ id: "c1", raw: usd, rawPrinting: "Holofoil", source,
      conditions: { "Near Mint": usd }, printings: { "Holofoil": { usd, matrix: { "Near Mint": usd } } } });
    expect(run([card(111, 10)], [card(111, 12)])("raw")).toBeCloseTo(0.2);
    rmSync(dir, { recursive: true, force: true }); dir = mkdtempSync(join(tmpdir(), "sanity-"));
    const preSource = FULL_SCHEMA.replace(" price_source INTEGER,", "");
    expect(run([card(null, 10)], [card(222, 12)], preSource)("raw")).toBeCloseTo(0.2);
  });

  it("small inversions are noise, not evidence — Damaged a little over Heavily Played keeps everything", () => {
    const ladder = (k: number): Ladder => ({ "Near Mint": 20 * k, "Lightly Played": 15 * k, "Moderately Played": 9 * k,
                                              "Heavily Played": 5.36 * k, "Damaged": 5.6 * k });
    const card = (k: number) => ({ id: "c1", raw: 20 * k, rawPrinting: "Normal", conditions: ladder(k),
      printings: { "Normal": { usd: 20 * k, matrix: ladder(k) } } });
    const pct = run([card(1)], [card(1.1)]);
    for (const [kind, key] of [["raw", ""], ["printing", "Normal"], ["matrix", "Normal|Damaged"],
                               ["matrix", "Normal|Heavily Played"], ["condition", "Damaged"]])
      expect(pct(kind, key)).toBeCloseTo(0.1);
  });

  it("a bad pair low on the ladder blanks only that pair, not the printing it doesn't quote", () => {
    // Heavily Played at 3× Moderately Played: one of them is a bad print. Near Mint, which the
    // printing quotes, is coherent — so the printing, raw and the other cells keep their deltas.
    const ladder = (k: number): Ladder => ({ "Near Mint": 20 * k, "Lightly Played": 15 * k, "Moderately Played": 3 * k,
                                              "Heavily Played": 9 * k, "Damaged": 2 * k });
    const card = (k: number) => ({ id: "c1", raw: 20 * k, rawPrinting: "Holofoil",
      printings: { "Holofoil": { usd: 20 * k, matrix: ladder(k) } } });
    const pct = run([card(1)], [card(1.2)]);
    expect(pct("matrix", "Holofoil|Moderately Played")).toBeUndefined();
    expect(pct("matrix", "Holofoil|Heavily Played")).toBeUndefined();
    expect(pct("matrix", "Holofoil|Near Mint")).toBeCloseTo(0.2);
    expect(pct("matrix", "Holofoil|Damaged")).toBeCloseTo(0.2);
    expect(pct("printing", "Holofoil")).toBeCloseTo(0.2);
    expect(pct("raw")).toBeCloseTo(0.2);
  });

  it("Rayquaza: a printing price that changed WHICH condition it quotes is not a move", () => {
    const old = [{ id: "ex9-9", printings: { "Normal": { usd: 112.06, matrix: { "Lightly Played": 112.06, "Damaged": 49.99 } } } }];
    const now = [{ id: "ex9-9", printings: { "Normal": { usd: 400, matrix: { "Near Mint": 400, "Lightly Played": 112.06, "Damaged": 49.99 } } } }];
    const pct = run(old, now);
    expect(pct("printing", "Normal")).toBeUndefined();                     // was +257.0%: LP one night, NM the next
    expect(pct("matrix", "Normal|Lightly Played")).toBeCloseTo(0);        // the cells themselves didn't move
  });

  it("a one-condition ladder can't be checked, so its printing gets no delta", () => {
    const card = (usd: number) => ({ id: "ecard3-146", printings: { "Reverse Holofoil": { usd, matrix: { "Damaged": usd } } } });
    expect(run([card(799.99)], [card(2999.99)])("printing", "Reverse Holofoil")).toBeUndefined();  // was +275%
  });

  it("Blaziken: a grade ladder running backwards blanks the grades involved", () => {
    const g = (usd: number) => ({ usd, sales: 9 });
    const old = [{ id: "pl3-142", psa: { 7: g(136), 8: g(240.22), 9: g(849.48), 10: g(16) } }];
    const now = [{ id: "pl3-142", psa: { 7: g(112.14), 8: g(1024), 9: g(2990), 10: g(54997.47) } }];
    const pct = run(old, now);
    expect(pct("psa", "10")).toBeUndefined();                              // was +343,634%: PSA 10 $16 under PSA 7 $136
    expect(pct("psa", "7")).toBeCloseTo(112.14 / 136 - 1);                 // the odd one out goes alone: PSA 7 keeps -17.5%
  });

  it("Togepi: a witness has to be in proportion, not merely present", () => {
    const g = (usd: number) => ({ usd, sales: 4 });
    const pct = run([{ id: "si1-4", psa: { 6: g(100), 8: g(300), 10: g(222.5) } }],
                    [{ id: "si1-4", psa: { 6: g(140.7), 8: g(450.6), 10: g(150000) } }]);
    expect(pct("psa", "10")).toBeUndefined();                              // +67,316% on a +50% witness
    expect(pct("psa", "8")).toBeCloseTo(0.502);                            // PSA 6 +40.7% vouches for PSA 8's +50.2%
  });

  it("Corphish: a quote that jumps alone on a frozen ladder is not a market move", () => {
    const ladder = (nm: number, lp: number): Ladder => ({ "Near Mint": nm, "Lightly Played": lp,
      "Moderately Played": 3.17, "Heavily Played": 2.99, "Damaged": 3.0 });
    const card = (nm: number, lp: number) => ({ id: "ex4-51", printings: { "Reverse Holofoil": { usd: nm, matrix: ladder(nm, lp) } } });
    const pct = run([card(10.45, 7.27)], [card(49.99, 8.64)]);
    expect(pct("printing", "Reverse Holofoil")).toBeUndefined();          // was +378.4%, Market #1
    expect(pct("matrix", "Reverse Holofoil|Near Mint")).toBeUndefined();
    expect(pct("matrix", "Reverse Holofoil|Lightly Played")).toBeCloseTo(8.64 / 7.27 - 1);  // +18.8%: under the bar, stands
  });

  it("a whole ladder that moves together is a real move, up or down", () => {
    const ladder = (k: number): Ladder => Object.fromEntries(Object.entries(sane).map(([c, v]) => [c, v * k])) as Ladder;
    const card = (k: number) => ({ id: "c1", raw: 20 * k, rawPrinting: "Holofoil", conditions: ladder(k),
      printings: { "Holofoil": { usd: 20 * k, matrix: ladder(k) } } });
    const up = run([card(1)], [card(2.9)]);
    for (const [kind, key] of [["raw", ""], ["printing", "Holofoil"], ["matrix", "Holofoil|Near Mint"], ["condition", "Near Mint"]])
      expect(up(kind, key)).toBeCloseTo(1.9);
    rmSync(dir, { recursive: true, force: true }); dir = mkdtempSync(join(tmpdir(), "sanity-"));
    expect(run([card(1)], [card(0.4)])("printing", "Holofoil")).toBeCloseTo(-0.6);
  });

  it("a big drop with nothing else falling is dropped too, and so is a lone card-level jump", () => {
    const card = (nm: number) => ({ id: "c1", raw: nm, rawPrinting: "Holofoil",
      conditions: { "Near Mint": nm, "Lightly Played": 6, "Damaged": 2 },
      printings: { "Holofoil": { usd: nm, matrix: { "Near Mint": nm, "Lightly Played": 6, "Damaged": 2 } } } });
    const down = run([card(20)], [card(8)]);
    expect(down("printing", "Holofoil")).toBeUndefined();                  // -60%, LP and DMG flat
    expect(down("raw")).toBeUndefined();
    expect(down("condition", "Near Mint")).toBeUndefined();
    expect(down("condition", "Lightly Played")).toBeCloseTo(0);
  });

  it("a healthy card loses nothing", () => {
    const card = (k: number) => ({ id: "ok", raw: 20 * k, rawPrinting: "Holofoil",
      psa: { 10: { usd: 300 * k, sales: 8 } },
      conditions: Object.fromEntries(Object.entries(sane).map(([c, v]) => [c, v * k])) as Ladder,
      printings: { "Holofoil": { usd: 20 * k, matrix: Object.fromEntries(Object.entries(sane).map(([c, v]) => [c, v * k])) as Ladder } } });
    const pct = run([card(1)], [card(1.1)]);
    expect(pct("raw")).toBeCloseTo(0.1);
    expect(pct("psa", "10")).toBeCloseTo(0.1);
    expect(pct("condition", "Lightly Played")).toBeCloseTo(0.1);
    expect(pct("printing", "Holofoil")).toBeCloseTo(0.1);
    expect(pct("matrix", "Holofoil|Damaged")).toBeCloseTo(0.1);
  });
});
