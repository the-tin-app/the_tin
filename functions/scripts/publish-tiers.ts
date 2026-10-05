import Database from "better-sqlite3";
import { createHash } from "node:crypto";
import { gzipSync, gunzipSync } from "node:zlib";
import { mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { getStorage } from "firebase-admin/storage";
import { initializeApp, applicationDefault, getApps } from "firebase-admin/app";
import { AwsClient } from "aws4fetch";

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
  const lookbacks: DeltaLookback[] = [];
  for (const lb of LOOKBACKS) {
    const artifact = pickLookbackArtifact(catalogDir, now, lb);
    if (artifact) lookbacks.push({ col: lb.col, gzPath: join(catalogDir, artifact) });
  }
  computePriceDeltasFrom(sourceDbPath, lookbacks);
}

export interface DeltaLookback { col: (typeof LOOKBACKS)[number]["col"]; gzPath: string }

/** Graded deltas need at least this many sales behind the grade tonight. A PSA 10 quoted off one
 *  sale moved +343,634% in a month (Blaziken FB LV.X, 2026-10-04); a price that thin is a
 *  listing, not a market. */
const MIN_GRADED_SALES = 3;

/** Better condition → lower rank. NULL for anything else — PPT leaks printing names into the
 *  condition column, and an unranked row must never vote on a ladder. */
const CONDITION_RANK = (col: string) => `CASE ${col}
  WHEN 'Near Mint' THEN 0 WHEN 'Lightly Played' THEN 1 WHEN 'Moderately Played' THEN 2
  WHEN 'Heavily Played' THEN 3 WHEN 'Damaged' THEN 4 END`;

/**
 * `computePriceDeltas` with the lookback artifacts named explicitly — what `validate-deltas.ts`
 * runs against preserved artifacts, never a served catalog dir. MUTATES sourceDbPath.
 *
 * A delta is the difference between two single-night PPT snapshots, and for thin markets either
 * night can be garbage. Measured 2026-10-04 (v92 vs v62): 512 rows past +500%, and the screen
 * showed the band just under the app's clamp — Sceptile's Reverse Holofoil at +454.9% while its
 * history moved +16.8%. So a delta is only written when both nights describe something coherent:
 *
 * 1. **Ladder** — on BOTH nights, a printing's condition prices must run NM ≥ LP ≥ MP ≥ HP ≥ DMG.
 *    Sceptile's Sep 4 Reverse Holofoil had NM $2.97 under Damaged $4.24. A night like that
 *    blanks the printing's `printing` and `matrix` deltas, and `raw` when raw quotes that
 *    printing (Kyogre Star: MP $299.99 under HP $600 — the case the raw_printing label guard
 *    let through, because the label matched). The card-level condition ladder gates `condition`.
 * 2. **No ladder, no printing delta** — a `price_by_variant` row with no `price_matrix` rows is
 *    not a printing this pipeline models: "Miscellaneous Cards & Products", "League &
 *    Championship Cards" (PPT category buckets), and the print runs PPT prices without a
 *    condition breakdown. Nothing can validate those, and they carried the +1465% / +443% rows.
 * 3. **Thin graded** — a `psa` delta needs ≥ MIN_GRADED_SALES sales behind that grade tonight.
 * 4. **Same product** — when both nights record `price_source` (the PPT product the card's prices
 *    came from), a card whose product changed gets no delta of any kind: that is two products,
 *    not one product's move. Artifacts from before the column skip this check.
 *
 * Each rule applies only where both databases carry what it reads, so older artifacts keep the
 * behaviour they had rather than going blank.
 */
export function computePriceDeltasFrom(sourceDbPath: string, lookbacks: DeltaLookback[]): void {
  const db = new Database(sourceDbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS price_delta(
      card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
      pct_1d REAL, pct_7d REAL, pct_30d REAL,
      PRIMARY KEY(card_id, kind, key));
    CREATE INDEX IF NOT EXISTS idx_price_delta_card ON price_delta(card_id);
    DELETE FROM price_delta;`);
  const tables = (schema: string) => new Set((db.prepare(
    `SELECT name FROM ${schema}.sqlite_master WHERE type='table'`).all() as { name: string }[])
    .map((t) => t.name));
  const columns = (schema: string, table: string) => new Set((db.pragma(
    `${schema}.table_info(${table})`) as { name: string }[]).map((c) => c.name));
  const brokenLadders = (schema: string) => `
    SELECT DISTINCT a.card_id, a.printing FROM ${schema}.price_matrix a
    JOIN ${schema}.price_matrix b ON b.card_id = a.card_id AND b.printing = a.printing
    WHERE ${CONDITION_RANK("a.condition")} < ${CONDITION_RANK("b.condition")} AND a.usd < b.usd`;
  const brokenCardLadders = (schema: string) => `
    SELECT DISTINCT a.card_id FROM ${schema}.price_by_condition a
    JOIN ${schema}.price_by_condition b ON b.card_id = a.card_id
    WHERE ${CONDITION_RANK("a.condition")} < ${CONDITION_RANK("b.condition")} AND a.usd < b.usd`;

  const newTables = tables("main");
  const newLatest = columns("main", "price_latest");
  const newHasMatrix = newTables.has("price_matrix");
  try {
    for (const lb of lookbacks) {
      // OS tempdir, not catalogDir — a leaked temp (ATTACH throws on a corrupt/partial artifact)
      // must never land in the served catalog dir, where the prune regex never touches it.
      const tmp = join(tmpdir(), `_delta-lookback-${lb.col}-${process.pid}-${Date.now()}.sqlite`);
      const artifact = lb.gzPath;
      let attached = false;
      // Per-lookback isolation: one bad/old-schema artifact must not kill the other windows
      // (2026-07-19: a pre-psa-widening 7d artifact aborted 7d cond/psa/printing AND all of 30d).
      try {
        if (artifact.endsWith(".gz")) writeFileSync(tmp, gunzipSync(readFileSync(artifact)));
        else copyFileSync(artifact, tmp);
        db.exec(`ATTACH DATABASE '${tmp.replace(/'/g, "''")}' AS old`);
        attached = true;
        const upsert = (select: string) => db.exec(`
          INSERT INTO price_delta(card_id, kind, key, ${lb.col}) ${select}
          ON CONFLICT(card_id, kind, key) DO UPDATE SET ${lb.col} = excluded.${lb.col}`);
        const oldCols = columns("old", "price_latest");
        const oldTables = tables("old");
        const bothMatrix = newHasMatrix && oldTables.has("price_matrix");

        // ---- the sanity sets (rules 1, 2, 4), rebuilt per lookback: half of each is `old` ----
        db.exec(`
          DROP TABLE IF EXISTS temp._bad_printing; DROP TABLE IF EXISTS temp._bad_card;
          DROP TABLE IF EXISTS temp._moved_source;
          CREATE TEMP TABLE _bad_printing(card_id TEXT, printing TEXT, PRIMARY KEY(card_id, printing));
          CREATE TEMP TABLE _bad_card(card_id TEXT PRIMARY KEY);
          CREATE TEMP TABLE _moved_source(card_id TEXT PRIMARY KEY);`);
        if (newHasMatrix) db.exec(`INSERT OR IGNORE INTO _bad_printing ${brokenLadders("main")}`);
        if (oldTables.has("price_matrix")) db.exec(`INSERT OR IGNORE INTO _bad_printing ${brokenLadders("old")}`);
        db.exec(`INSERT OR IGNORE INTO _bad_card ${brokenCardLadders("main")}`);
        db.exec(`INSERT OR IGNORE INTO _bad_card ${brokenCardLadders("old")}`);
        if (newLatest.has("price_source") && oldCols.has("price_source")) {
          db.exec(`INSERT OR IGNORE INTO _moved_source
                   SELECT n.card_id FROM main.price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                   WHERE o.price_source IS NOT n.price_source`);
        }
        const sameSource = "AND n.card_id NOT IN (SELECT card_id FROM temp._moved_source)";
        const printingLadderOk = (printing: string) =>
          `AND NOT EXISTS (SELECT 1 FROM temp._bad_printing bp WHERE bp.card_id = n.card_id AND bp.printing = ${printing})`;

        // raw_usd quotes whichever printing had a market price that night, so the same column can
        // describe a different printing in each artifact. Diffing across a flip measures the SPREAD
        // BETWEEN TWO PRINTINGS, not a price move (+1800% rows, 2026-07-25). Requiring the basis to
        // match means a flipped card simply yields no raw delta that window — the honest answer,
        // since a move cannot be measured across a change of subject.
        //
        // Artifacts published before this column existed can't be checked. Those fall back to the
        // old card_id-only join rather than blacking out every raw delta for the 30 days it takes
        // the ledger to age over: 1d is correct after one nightly, 7d after a week, 30d after a
        // month, and the client's implausible-pct clamp still covers the gap.
        //
        // A matching label is NOT a matching subject, though: Kyogre Star kept 'Holofoil' both
        // nights while one of them was garbage. Rule 1 (the ladder of the printing raw quotes)
        // is what catches that.
        const basisMatch = oldCols.has("raw_printing")
          ? "AND (o.raw_printing IS n.raw_printing)"   // IS, not =: NULL basis must match NULL basis
          : "";
        if (!basisMatch) {
          console.warn(`[publish-tiers] ${lb.col} lookback vs ${artifact} predates raw_printing —` +
            " raw deltas for this window are unverified (basis flips can still slip through)");
        }
        const rawLadder = newLatest.has("raw_printing") ? printingLadderOk("n.raw_printing") : "";
        upsert(`SELECT n.card_id, 'raw', '', (n.raw_usd - o.raw_usd) / o.raw_usd
                FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id ${basisMatch}
                WHERE n.raw_usd > 0 AND o.raw_usd > 0 ${rawLadder} ${sameSource}`);
        // Artifacts published before the psa1-10 widening only carry psa8-10.
        const gradedGate = newTables.has("graded_sales")
          ? (g: number) => `AND EXISTS (SELECT 1 FROM main.graded_sales gs WHERE gs.card_id = n.card_id
                              AND gs.grade = 'psa${g}' AND gs.sales_count >= ${MIN_GRADED_SALES})`
          : () => "";
        for (let g = 1; g <= 10; g++) {
          if (!oldCols.has(`psa${g}`)) continue;
          upsert(`SELECT n.card_id, 'psa', '${g}', (n.psa${g} - o.psa${g}) / o.psa${g}
                  FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                  WHERE n.psa${g} > 0 AND o.psa${g} > 0 ${gradedGate(g)} ${sameSource}`);
        }
        upsert(`SELECT n.card_id, 'condition', n.condition, (n.usd - o.usd) / o.usd
                FROM price_by_condition n JOIN old.price_by_condition o
                  ON o.card_id = n.card_id AND o.condition = n.condition
                WHERE n.usd > 0 AND o.usd > 0
                  AND n.card_id NOT IN (SELECT card_id FROM temp._bad_card) ${sameSource}`);
        // Rule 2: a printing is only diffed where this pipeline models it — a condition ladder on
        // each night that has the table.
        const laddered = (newHasMatrix
          ? "AND EXISTS (SELECT 1 FROM main.price_matrix m WHERE m.card_id = n.card_id AND m.printing = n.printing)" : "")
          + (oldTables.has("price_matrix")
          ? " AND EXISTS (SELECT 1 FROM old.price_matrix m WHERE m.card_id = n.card_id AND m.printing = n.printing)" : "");
        upsert(`SELECT n.card_id, 'printing', n.printing, (n.usd - o.usd) / o.usd
                FROM price_by_variant n JOIN old.price_by_variant o
                  ON o.card_id = n.card_id AND o.printing = n.printing
                WHERE n.usd > 0 AND o.usd > 0 ${laddered} ${printingLadderOk("n.printing")} ${sameSource}`);
        // Matrix deltas: keyed "printing|condition" ('|' appears in neither PPT key set).
        // Guarded like the psa-column probe — artifacts published before the matrix feature
        // have no price_matrix table, and one missing table must not abort the window's
        // remaining upserts (they already ran) or log a scary failure for a normal rollout.
        if (bothMatrix) {
          upsert(`SELECT n.card_id, 'matrix', n.printing || '|' || n.condition, (n.usd - o.usd) / o.usd
                  FROM price_matrix n JOIN old.price_matrix o
                    ON o.card_id = n.card_id AND o.printing = n.printing AND o.condition = n.condition
                  WHERE n.usd > 0 AND o.usd > 0 ${printingLadderOk("n.printing")} ${sameSource}`);
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

const RETENTION_DAYS = 45;   // expert ONLY — see pruneOldArtifacts
const KEEP_VERSIONS = 3;     // casual/average — pure rollback material, never read back

/** Prune published tier artifacts, and never one the just-written manifest references.
 *
 *  Retention is asymmetric on purpose. `expert-v*` is not a backup — it is the price-delta
 *  ledger: computePriceDeltas ATTACHes prior expert artifacts aged 0.5–3d, 5–10d and 25–40d
 *  (see pickLookbackArtifact), so pruning it by version count silently empties pct_7d and
 *  pct_30d — no error, just blank Movers. Age is the only correct rule there.
 *  casual/average are read by nothing but a human doing a rollback, so 3 versions is plenty.
 *  Returns deleted names. */
export function pruneOldArtifacts(catalogDir: string, manifest: NasManifest, now: Date): string[] {
  const keep = new Set(Object.values(manifest.tiers).map((t) => t.path));
  const byTier = new Map<string, { f: string; v: number }[]>();
  for (const f of readdirSync(catalogDir)) {
    const m = /^(casual|average|expert)-v(\d+)\.sqlite\.gz$/.exec(f);
    if (!m || keep.has(f)) continue;
    byTier.set(m[1], [...(byTier.get(m[1]) ?? []), { f, v: Number(m[2]) }]);
  }

  const deleted: string[] = [];
  const drop = (f: string) => { unlinkSync(join(catalogDir, f)); deleted.push(f); };

  for (const [tier, files] of byTier) {
    if (tier === "expert") {
      for (const { f } of files) {
        if ((now.getTime() - statSync(join(catalogDir, f)).mtimeMs) / DAY_MS > RETENTION_DAYS) drop(f);
      }
    } else {
      // Newest version first. The manifest's own copy was excluded above and counts as one of
      // the KEEP_VERSIONS, so KEEP_VERSIONS - 1 survive from this list.
      files.sort((a, b) => b.v - a.v);
      for (const { f } of files.slice(KEEP_VERSIONS - 1)) drop(f);
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
  /** Optional R2 backup origin. Receives the SAME bytes and the SAME tiered layout as the NAS —
   *  that identical layout is what lets the iOS client use one remote implementation for both. */
  r2?: StoragePort;
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

  const uploads: { path: string; gz: Buffer }[] = [];
  const writeTier = (tier: string, dbPath: string): TierEntry => {
    const gz = gzipSync(readFileSync(dbPath));
    const path = `${tier}-v${opts.version}.sqlite.gz`;
    writeFileSync(join(catalogDir, path), gz);
    uploads.push({ path, gz });
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

  // R2 backup origin. Artifacts FIRST, manifest LAST — a manifest naming objects that are not
  // served yet strands every client that reads it (same rule as the fingerprint parts publish).
  if (opts.r2) {
    for (const u of uploads) await opts.r2.save(`catalog/${u.path}`, u.gz, "application/gzip");
    await opts.r2.save("catalog/manifest.json", Buffer.from(JSON.stringify(manifest)), "application/json");
    console.log(`  r2: uploaded ${uploads.length} tier(s) + manifest for v${opts.version}`);
  }

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

/** R2 over its S3-compatible API. Objects here are <5 GB, so a plain signed PUT is enough and no
 *  multipart machinery is needed. */
export class R2Storage implements StoragePort {
  private readonly client: AwsClient;
  constructor(
    private readonly accountId: string,
    private readonly bucket: string,
    accessKeyId: string,
    secretAccessKey: string,
  ) {
    this.client = new AwsClient({ accessKeyId, secretAccessKey, service: "s3", region: "auto" });
  }

  async save(path: string, data: Buffer, contentType: string) {
    const url = `https://${this.accountId}.r2.cloudflarestorage.com/${this.bucket}/${path}`;
    const res = await this.client.fetch(url, {
      method: "PUT", body: data, headers: { "content-type": contentType },
    });
    if (!res.ok) throw new Error(`R2 PUT ${path} failed: ${res.status} ${await res.text()}`);
  }
}

function r2FromEnv(): R2Storage | undefined {
  const { R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY } = process.env;
  if (!R2_ACCOUNT_ID || !R2_BUCKET || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) return undefined;
  return new R2Storage(R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY);
}

async function main() {
  const [sourceDbPath, versionArg, nasDir] = process.argv.slice(2);
  const publishToFirebase = process.argv.includes("--firebase");
  if (!sourceDbPath || !versionArg || !nasDir) {
    console.error("usage: publish-tiers.ts <sourceDbPath> <version> <nasDir> [--firebase] [--r2]");
    process.exit(1);
  }
  if (publishToFirebase && !BUCKET) {
    console.error("--firebase requires FIREBASE_STORAGE_BUCKET (e.g. <project>.firebasestorage.app)");
    process.exit(1);
  }
  const publishToR2 = process.argv.includes("--r2");
  const r2 = publishToR2 ? r2FromEnv() : undefined;
  if (publishToR2 && !r2) {
    console.error("--r2 requires R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY");
    process.exit(1);
  }
  const m = await publishTiers({
    sourceDbPath, version: Number(versionArg), nasDir,
    firebaseStorage: new BucketStorage(), now: new Date(), publishToFirebase, r2,
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
