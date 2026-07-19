import Database from "better-sqlite3";
import { createHash } from "node:crypto";
import { gzipSync, gunzipSync } from "node:zlib";
import { mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { getStorage } from "firebase-admin/storage";
import { initializeApp, applicationDefault, getApps } from "firebase-admin/app";

// Only these two tables are ever physically dropped: they are the only tables the iOS app never
// queries (verified against ios/TCGApp/Sources/**). Every other table the app reads stays present.
const BACKEND_ONLY_TABLES = ["price_history_cond", "graded_history"];

export function splitTiers(sourceDbPath: string, outDir: string): {
  casualPath: string; averagePath: string; expertPath: string;
} {
  mkdirSync(outDir, { recursive: true });
  const casualPath = join(outDir, "casual.sqlite");
  const averagePath = join(outDir, "average.sqlite");
  const expertPath = join(outDir, "expert.sqlite");

  // expert = full DB, untouched.
  copyFileSync(sourceDbPath, expertPath);

  // average = full minus the two backend-only history tables.
  copyFileSync(sourceDbPath, averagePath);
  const average = new Database(averagePath);
  for (const t of BACKEND_ONLY_TABLES) average.exec(`DROP TABLE IF EXISTS "${t}"`);
  average.exec("VACUUM");
  average.close();

  // casual = average, and additionally EMPTY price_history (keep the table so the app's sparkline
  // query returns no rows instead of failing on a missing table). Guarded — some test fixtures
  // (and older sources) don't have every history table.
  copyFileSync(averagePath, casualPath);
  const casual = new Database(casualPath);
  const hasTable = (name: string) =>
    !!casual.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
  if (hasTable("price_history")) casual.exec("DELETE FROM price_history");
  // price_delta mirrors the price_history pattern: casual keeps the table, zero rows. Guarded —
  // a source built before this feature (or a direct splitTiers call in tests) has no table.
  if (hasTable("price_delta")) casual.exec("DELETE FROM price_delta");
  casual.exec("VACUUM");
  casual.close();

  return { casualPath, averagePath, expertPath };
}

const DAY_MS = 86_400_000;
const LOOKBACKS = [
  { col: "pct_1d", target: 1, min: 0.5, max: 3 },
  { col: "pct_7d", target: 7, min: 5, max: 10 },
  { col: "pct_30d", target: 30, min: 25, max: 40 },
] as const;

/** The published expert artifact whose mtime age (days before `now`) falls inside [min, max],
 *  closest to `target`. Null when none qualifies (that lookback column stays NULL). */
function pickLookbackArtifact(catalogDir: string, now: Date,
                              lb: (typeof LOOKBACKS)[number]): string | null {
  const candidates = readdirSync(catalogDir)
    .filter((f) => /^expert-v\d+\.sqlite\.gz$/.test(f))
    .map((f) => ({ f, age: (now.getTime() - statSync(join(catalogDir, f)).mtimeMs) / DAY_MS }))
    .filter((c) => c.age >= lb.min && c.age <= lb.max)
    .sort((a, b) => Math.abs(a.age - lb.target) - Math.abs(b.age - lb.target));
  return candidates[0]?.f ?? null;
}

/**
 * Diff the freshly built catalog against prior published expert artifacts (the NAS catalog dir
 * doubles as a daily price ledger) and write `price_delta` into the SOURCE DB, so every tier
 * inherits it through the split. Old artifacts are the only source covering printings (no
 * history table) and grades/conditions below the expert tier. MUTATES sourceDbPath.
 */
export function computePriceDeltas(sourceDbPath: string, catalogDir: string, now: Date): void {
  const db = new Database(sourceDbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS price_delta(
      card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
      pct_1d REAL, pct_7d REAL, pct_30d REAL,
      PRIMARY KEY(card_id, kind, key));
    CREATE INDEX IF NOT EXISTS idx_price_delta_card ON price_delta(card_id);
    DELETE FROM price_delta;`);
  try {
    for (const lb of LOOKBACKS) {
      const artifact = pickLookbackArtifact(catalogDir, now, lb);
      if (!artifact) continue;
      // OS tempdir, not catalogDir — a leaked temp (ATTACH throws on a corrupt/partial artifact)
      // must never land in the served catalog dir, where the prune regex never touches it.
      const tmp = join(tmpdir(), `_delta-lookback-${lb.col}-${process.pid}-${Date.now()}.sqlite`);
      let attached = false;
      // Per-lookback isolation: one bad/old-schema artifact must not kill the other windows
      // (2026-07-19: a pre-psa-widening 7d artifact aborted 7d cond/psa/printing AND all of 30d).
      try {
        writeFileSync(tmp, gunzipSync(readFileSync(join(catalogDir, artifact))));
        db.exec(`ATTACH DATABASE '${tmp.replace(/'/g, "''")}' AS old`);
        attached = true;
        const upsert = (select: string) => db.exec(`
          INSERT INTO price_delta(card_id, kind, key, ${lb.col}) ${select}
          ON CONFLICT(card_id, kind, key) DO UPDATE SET ${lb.col} = excluded.${lb.col}`);
        upsert(`SELECT n.card_id, 'raw', '', (n.raw_usd - o.raw_usd) / o.raw_usd
                FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                WHERE n.raw_usd > 0 AND o.raw_usd > 0`);
        // Artifacts published before the psa1-10 widening only carry psa8-10.
        const oldCols = new Set((db.pragma("old.table_info(price_latest)") as
          { name: string }[]).map((c) => c.name));
        for (let g = 1; g <= 10; g++) {
          if (!oldCols.has(`psa${g}`)) continue;
          upsert(`SELECT n.card_id, 'psa', '${g}', (n.psa${g} - o.psa${g}) / o.psa${g}
                  FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                  WHERE n.psa${g} > 0 AND o.psa${g} > 0`);
        }
        upsert(`SELECT n.card_id, 'condition', n.condition, (n.usd - o.usd) / o.usd
                FROM price_by_condition n JOIN old.price_by_condition o
                  ON o.card_id = n.card_id AND o.condition = n.condition
                WHERE n.usd > 0 AND o.usd > 0`);
        upsert(`SELECT n.card_id, 'printing', n.printing, (n.usd - o.usd) / o.usd
                FROM price_by_variant n JOIN old.price_by_variant o
                  ON o.card_id = n.card_id AND o.printing = n.printing
                WHERE n.usd > 0 AND o.usd > 0`);
        // Matrix deltas: keyed "printing|condition" ('|' appears in neither PPT key set).
        // Guarded like the psa-column probe — artifacts published before the matrix feature
        // have no price_matrix table, and one missing table must not abort the window's
        // remaining upserts (they already ran) or log a scary failure for a normal rollout.
        const oldTables = new Set((db.prepare(
          "SELECT name FROM old.sqlite_master WHERE type='table'").all() as { name: string }[])
          .map((t) => t.name));
        if (oldTables.has("price_matrix")) {
          upsert(`SELECT n.card_id, 'matrix', n.printing || '|' || n.condition, (n.usd - o.usd) / o.usd
                  FROM price_matrix n JOIN old.price_matrix o
                    ON o.card_id = n.card_id AND o.printing = n.printing AND o.condition = n.condition
                  WHERE n.usd > 0 AND o.usd > 0`);
        }
      } catch (e) {
        console.warn(`[publish-tiers] ${lb.col} lookback vs ${artifact} failed — skipping:`, e);
      } finally {
        // Delete the temp file FIRST: if ATTACH failed partway (corrupt/partial sqlite), DETACH
        // below throws "no such database: old", which — if it ran first — would mask the real
        // error AND abort before rmSync, orphaning a large uncompressed sqlite outside catalogDir.
        rmSync(tmp, { force: true });
        if (attached) {
          try { db.exec("DETACH DATABASE old"); } catch { /* swallow: never mask the real error */ }
        }
      }
    }
  } finally {
    db.close();
  }
}

const RETENTION_DAYS = 45;

/** Delete tier artifacts older than RETENTION_DAYS (mtime) — the delta lookback only needs 40
 *  days back — but never a file the just-written manifest references. Returns deleted names. */
export function pruneOldArtifacts(catalogDir: string, manifest: NasManifest, now: Date): string[] {
  const keep = new Set(Object.values(manifest.tiers).map((t) => t.path));
  const deleted: string[] = [];
  for (const f of readdirSync(catalogDir)) {
    if (!/^(casual|average|expert)-v\d+\.sqlite\.gz$/.test(f) || keep.has(f)) continue;
    if ((now.getTime() - statSync(join(catalogDir, f)).mtimeMs) / DAY_MS > RETENTION_DAYS) {
      unlinkSync(join(catalogDir, f));
      deleted.push(f);
    }
  }
  return deleted;
}

export interface TierEntry { path: string; sha256: string; sizeBytes: number }

export interface NasManifest {
  version: number;
  generatedAt: string;
  tiers: { casual: TierEntry; average: TierEntry; expert: TierEntry };
}

export async function publishTiers(opts: {
  sourceDbPath: string; version: number; nasDir: string;
  firebaseStorage: StoragePort; now: Date; publishToFirebase: boolean;
}): Promise<NasManifest> {
  const catalogDir = join(opts.nasDir, "catalog");
  mkdirSync(catalogDir, { recursive: true });

  // Deltas diff against PRIOR artifacts, so this must run before today's tiers are written —
  // and must never block a publish: a catalog without deltas beats no catalog.
  try {
    computePriceDeltas(opts.sourceDbPath, catalogDir, opts.now);
  } catch (e) {
    console.warn("[publish-tiers] price_delta computation failed — publishing without deltas:", e);
  }

  const { casualPath, averagePath, expertPath } = splitTiers(opts.sourceDbPath, join(opts.nasDir, "_work"));

  const writeTier = (tier: string, dbPath: string): TierEntry => {
    const gz = gzipSync(readFileSync(dbPath));
    const path = `${tier}-v${opts.version}.sqlite.gz`;
    writeFileSync(join(catalogDir, path), gz);
    return { path, sha256: createHash("sha256").update(gz).digest("hex"), sizeBytes: gz.length };
  };

  const manifest: NasManifest = {
    version: opts.version,
    generatedAt: opts.now.toISOString(),
    tiers: {
      casual: writeTier("casual", casualPath),
      average: writeTier("average", averagePath),
      expert: writeTier("expert", expertPath),
    },
  };
  writeFileSync(join(catalogDir, "manifest.json"), JSON.stringify(manifest));

  // Firebase backup: casual tier only, via the unchanged publishCatalog() (flat manifest + flat
  // catalog-vN.sqlite.gz). It gzips the SAME casual sqlite with the same deterministic gzip, so its
  // bytes are sha256-identical to the NAS casual artifact — asserted in publish-tiers.test.ts.
  if (opts.publishToFirebase) {
    await publishCatalog(casualPath, opts.version, opts.firebaseStorage, opts.now);
  }

  // The uncompressed split sqlites are already gzipped into catalogDir above; nothing else needs
  // the scratch copies, so clean them up (~850MB uncompressed across the three tiers).
  rmSync(join(opts.nasDir, "_work"), { recursive: true, force: true });

  const pruned = pruneOldArtifacts(catalogDir, manifest, opts.now);
  if (pruned.length) console.log(`  pruned ${pruned.length} artifact(s) older than 45d: ${pruned.join(", ")}`);

  return manifest;
}

// CLI: publish the three tiers from an already-built sqlite.
//   npx tsx scripts/publish-tiers.ts <sourceDbPath> <version> <nasDir> [--firebase]
// --firebase also pushes the casual tier to gs://$FIREBASE_STORAGE_BUCKET/catalog via
// applicationDefault creds — set FIREBASE_STORAGE_BUCKET to your own project's bucket.
const BUCKET = process.env.FIREBASE_STORAGE_BUCKET;

class BucketStorage implements StoragePort {
  async save(path: string, data: Buffer, contentType: string) {
    if (getApps().length === 0) initializeApp({ credential: applicationDefault(), storageBucket: BUCKET });
    await getStorage().bucket().file(path).save(data, { contentType });
  }
}

async function main() {
  const [sourceDbPath, versionArg, nasDir] = process.argv.slice(2);
  const publishToFirebase = process.argv.includes("--firebase");
  if (!sourceDbPath || !versionArg || !nasDir) {
    console.error("usage: publish-tiers.ts <sourceDbPath> <version> <nasDir> [--firebase]");
    process.exit(1);
  }
  if (publishToFirebase && !BUCKET) {
    console.error("--firebase requires FIREBASE_STORAGE_BUCKET (e.g. <project>.firebasestorage.app)");
    process.exit(1);
  }
  const m = await publishTiers({
    sourceDbPath, version: Number(versionArg), nasDir,
    firebaseStorage: new BucketStorage(), now: new Date(), publishToFirebase,
  });
  for (const tier of ["casual", "average", "expert"] as const) {
    const e = m.tiers[tier];
    console.log(`  ${tier.padEnd(8)} ${e.path}  ${(e.sizeBytes / 1e6).toFixed(1)} MB gz  sha ${e.sha256.slice(0, 12)}…`);
  }
  console.log(`  firebase(casual): ${publishToFirebase ? "PUBLISHED (sha matches NAS casual)" : "SKIPPED"}`);
}

if (require.main === module) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
