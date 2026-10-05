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

/** A move bigger than this needs a witness: another price on the same ladder (another condition
 *  of the printing, another grade of the card) moving at least WITNESS_MOVE the same way. A real
 *  market lifts more than one cell; a bad quote lifts only the cell being quoted. After rules 1–2
 *  the Market list was still led by single-cell jumps on frozen ladders — Team Aqua's Corphish
 *  Reverse Holofoil NM $10.45 → $49.99 while MP/HP/DMG sat byte-identical; 15 of the top 25 had
 *  no other cell move even 20% (v92 vs v62). */
const CORROBORATE_ABOVE = 0.5;
const WITNESS_MOVE = 0.2;
/** …and the witness must be in proportion: the headline may be at most this many times the
 *  witness's move. A witness that merely clears WITNESS_MOVE licensed a headline of any size — a
 *  Togepi PSA 10 at $222.50 → $150,000 (+67,316%) stood on a PSA 8 +50% (v92 vs v62). A real move
 *  lifts the ladder in the same order of magnitude; Zoroark's +292% stood on a DMG +423%. */
const MAX_OVER_WITNESS = 4;

/** How far a ladder may run backwards before it is evidence rather than noise. Thin markets
 *  routinely price Damaged a few cents over Heavily Played; that is not what broke the movers.
 *  What did was off by multiples — Sceptile NM $2.97 under LP $18.88 (6.4×), Kyogre Star MP
 *  $299.99 under HP $600 (2.0×), Blaziken PSA 10 $16 under PSA 7 $136 (8.5×). A strict "any
 *  inversion" rule removed ~60% of every window's deltas (validated 2026-10-04, v92), and blaming
 *  both sides of every pair still let one bad PSA 10 take out its whole grade ladder — so only the
 *  cell in the MOST inverted pairs is blamed (both, on a tie: then we can't tell which is wrong). */
const INVERSION_FACTOR = 1.5;

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
 * history moved +16.8%. So a delta is only written where both nights are coherent:
 *
 * 1. **Inversions** — on either night, prices on the same ladder that run backwards by more than
 *    INVERSION_FACTOR (a worse condition, or a lower grade, priced well above a better one) blame
 *    the cell caught in the most such pairs, and that cell gets no delta. Applies to a printing's
 *    condition cells (`price_matrix`), the card-level conditions, and the PSA grades (Blaziken's
 *    PSA 10 $16 under PSA 7 $136). A printing's own delta, and `raw`, quote the TOP of their
 *    ladder, so they go when that top cell does — which is what catches Kyogre Star, whose
 *    raw_printing label matched both nights while its MP sat at half its HP.
 * 2. **A modelled printing** — a printing delta needs, on each night that has the table, a ladder
 *    of at least two ranked conditions, and the SAME top condition on both nights. No ladder is a
 *    PPT category bucket ("Miscellaneous Cards & Products": Charizard's +443%, Meltan's +1465%); a
 *    ladder of one can't be checked (a Damaged-only cell shown as the market); and a different
 *    top condition means the variant price changed which condition it quotes (Rayquaza: LP $112
 *    one night, NM $400 the next — a change of subject, the raw_printing defect one axis down).
 *    `raw` gets the same-top check when its printing has a ladder on both nights.
 * 3. **Corroboration** — a move past ±CORROBORATE_ABOVE survives only with a witness on its own
 *    ladder moving ≥ WITNESS_MOVE the same way, and at least 1/MAX_OVER_WITNESS of the headline. A printing or `raw` is
 *    witnessed by its printing's OTHER conditions, never by the cell it quotes. (This replaced a
 *    minimum-sales gate on grades, which cost ~40% of graded deltas and still passed Blaziken,
 *    which had 11 sales.)
 * 4. **Same product** — when both nights record `price_source` (the PPT product the card's prices
 *    came from), a card whose product changed gets no delta of any kind. Artifacts from before
 *    the column skip this check.
 *
 * Each rule applies only where both databases carry what it reads, so older artifacts keep the
 * behaviour they had rather than going blank. Rules only ever REMOVE a delta; a kept delta is
 * computed exactly as before (validate-deltas.ts checks both).
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
  const rank = CONDITION_RANK;
  // Every pair on a ladder that runs backwards by more than INVERSION_FACTOR, as (card, ladder,
  // better cell, worse cell). `lad` names the ladder within a card: the printing for price_matrix,
  // '' for the card-level conditions and the grades.
  const matrixPairs = (schema: string) => `
    SELECT a.card_id AS card_id, a.printing AS lad, a.condition AS hi, b.condition AS lo
    FROM ${schema}.price_matrix a JOIN ${schema}.price_matrix b ON b.card_id = a.card_id AND b.printing = a.printing
    WHERE ${rank("a.condition")} < ${rank("b.condition")} AND b.usd > a.usd * ${INVERSION_FACTOR}`;
  const conditionPairs = (schema: string) => `
    SELECT a.card_id AS card_id, '' AS lad, a.condition AS hi, b.condition AS lo
    FROM ${schema}.price_by_condition a JOIN ${schema}.price_by_condition b ON b.card_id = a.card_id
    WHERE ${rank("a.condition")} < ${rank("b.condition")} AND b.usd > a.usd * ${INVERSION_FACTOR}`;
  const gradePairs = `
    SELECT a.card_id AS card_id, '' AS lad, CAST(a.grade AS TEXT) AS hi, CAST(b.grade AS TEXT) AS lo
    FROM temp._grades a JOIN temp._grades b ON b.card_id = a.card_id
    WHERE a.grade > b.grade AND b.usd > a.usd * ${INVERSION_FACTOR}`;
  /** Blame, per ladder, the cell(s) caught in the most inverted pairs, into `target(card_id,
   *  lad, cell)`. One bad cell inverts against many neighbours and is the clear odd one out; a
   *  lone pair is a tie, and then both are blamed because nothing says which is wrong. */
  const blame = (pairs: string, target: string) => db.exec(`
    DROP TABLE IF EXISTS temp._viol;
    CREATE TEMP TABLE _viol(card_id TEXT, lad TEXT, cell TEXT, n INTEGER, PRIMARY KEY(card_id, lad, cell));
    INSERT INTO _viol SELECT card_id, lad, cell, COUNT(*) FROM (
      SELECT card_id, lad, hi AS cell FROM (${pairs}) UNION ALL SELECT card_id, lad, lo FROM (${pairs}))
      GROUP BY card_id, lad, cell;
    INSERT OR IGNORE INTO ${target} SELECT v.card_id, v.lad, v.cell FROM _viol v
      WHERE v.n = (SELECT MAX(w.n) FROM _viol w WHERE w.card_id = v.card_id AND w.lad = v.lad);`);
  // price_latest's psaN columns as rows, so the grade ladder can be self-joined like the others.
  const gradeRows = (schema: string, cols: Set<string>) => Array.from({ length: 10 }, (_, i) => i + 1)
    .filter((g) => cols.has(`psa${g}`))
    .map((g) => `SELECT card_id, ${g} AS grade, psa${g} AS usd FROM ${schema}.price_latest WHERE psa${g} > 0`)
    .join(" UNION ALL ");
  // A printing's ladder summary: how many ranked conditions it has, and which one is its top.
  const ladders = (schema: string) => `
    SELECT card_id, printing, COUNT(*) AS n, MIN(${rank("condition")}) AS top
    FROM ${schema}.price_matrix WHERE ${rank("condition")} IS NOT NULL GROUP BY card_id, printing`;

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
        const oldHasMatrix = oldTables.has("price_matrix");

        // ---- the sanity sets, rebuilt per lookback: half of each comes from `old` ----
        db.exec(`
          DROP TABLE IF EXISTS temp._bad_cell; DROP TABLE IF EXISTS temp._bad_condition;
          DROP TABLE IF EXISTS temp._bad_grade; DROP TABLE IF EXISTS temp._moved_source;
          DROP TABLE IF EXISTS temp._ladder_new; DROP TABLE IF EXISTS temp._ladder_old;
          CREATE TEMP TABLE _bad_cell(card_id TEXT, printing TEXT, condition TEXT,
            PRIMARY KEY(card_id, printing, condition));
          CREATE TEMP TABLE _bad_condition(card_id TEXT, lad TEXT, condition TEXT, PRIMARY KEY(card_id, condition));
          CREATE TEMP TABLE _bad_grade(card_id TEXT, lad TEXT, grade TEXT, PRIMARY KEY(card_id, grade));
          CREATE TEMP TABLE _moved_source(card_id TEXT PRIMARY KEY);
          CREATE TEMP TABLE _ladder_new(card_id TEXT, printing TEXT, n INTEGER, top INTEGER,
            PRIMARY KEY(card_id, printing));
          CREATE TEMP TABLE _ladder_old(card_id TEXT, printing TEXT, n INTEGER, top INTEGER,
            PRIMARY KEY(card_id, printing));`);
        // Each night's ladders are judged on their own; a cell blamed on EITHER night is out.
        if (newHasMatrix) {
          blame(matrixPairs("main"), "_bad_cell");
          db.exec(`INSERT INTO _ladder_new ${ladders("main")}`);
        }
        if (oldHasMatrix) {
          blame(matrixPairs("old"), "_bad_cell");
          db.exec(`INSERT INTO _ladder_old ${ladders("old")}`);
        }
        blame(conditionPairs("main"), "_bad_condition");
        blame(conditionPairs("old"), "_bad_condition");
        for (const [schema, cols] of [["main", newLatest], ["old", oldCols]] as const) {
          const rows = gradeRows(schema, cols);
          if (!rows) continue;
          // Materialised and keyed first: a self-join of the bare 10-way UNION has no index to use,
          // and over ~200k grade rows that is a nested loop the nightly can't afford.
          db.exec(`DROP TABLE IF EXISTS temp._grades;
            CREATE TEMP TABLE _grades(card_id TEXT, grade INTEGER, usd REAL, PRIMARY KEY(card_id, grade));
            INSERT OR IGNORE INTO _grades ${rows};`);
          blame(gradePairs, "_bad_grade");
        }
        if (newLatest.has("price_source") && oldCols.has("price_source")) {
          db.exec(`INSERT OR IGNORE INTO _moved_source
                   SELECT n.card_id FROM main.price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                   WHERE o.price_source IS NOT n.price_source`);
        }
        const sameSource = "AND n.card_id NOT IN (SELECT card_id FROM temp._moved_source)";
        // The top cell of `printing` (an SQL expression) is disqualified on either night.
        const topCellOk = (printing: string) => `
          AND NOT EXISTS (SELECT 1 FROM temp._ladder_new l JOIN temp._bad_cell bc ON bc.card_id = l.card_id
                AND bc.printing = l.printing AND ${rank("bc.condition")} = l.top
                WHERE l.card_id = n.card_id AND l.printing = ${printing})
          AND NOT EXISTS (SELECT 1 FROM temp._ladder_old l JOIN temp._bad_cell bc ON bc.card_id = l.card_id
                AND bc.printing = l.printing AND ${rank("bc.condition")} = l.top
                WHERE l.card_id = n.card_id AND l.printing = ${printing})`;
        // Where both nights have a ladder for `printing`, it must quote the same condition.
        const sameTop = (printing: string) => `
          AND NOT EXISTS (SELECT 1 FROM temp._ladder_new ln JOIN temp._ladder_old lo
                ON lo.card_id = ln.card_id AND lo.printing = ln.printing
                WHERE ln.card_id = n.card_id AND ln.printing = ${printing} AND lo.top IS NOT ln.top)`;

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
        // nights while one of them was garbage. Rules 1 and 2, applied to the printing raw quotes,
        // are what catch that.
        const basisMatch = oldCols.has("raw_printing")
          ? "AND (o.raw_printing IS n.raw_printing)"   // IS, not =: NULL basis must match NULL basis
          : "";
        if (!basisMatch) {
          console.warn(`[publish-tiers] ${lb.col} lookback vs ${artifact} predates raw_printing —` +
            " raw deltas for this window are unverified (basis flips can still slip through)");
        }
        const rawChecks = newLatest.has("raw_printing")
          ? topCellOk("n.raw_printing") + sameTop("n.raw_printing") : "";
        upsert(`SELECT n.card_id, 'raw', '', (n.raw_usd - o.raw_usd) / o.raw_usd
                FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id ${basisMatch}
                WHERE n.raw_usd > 0 AND o.raw_usd > 0 ${rawChecks} ${sameSource}`);
        // Artifacts published before the psa1-10 widening only carry psa8-10.
        for (let g = 1; g <= 10; g++) {
          if (!oldCols.has(`psa${g}`)) continue;
          upsert(`SELECT n.card_id, 'psa', '${g}', (n.psa${g} - o.psa${g}) / o.psa${g}
                  FROM price_latest n JOIN old.price_latest o ON o.card_id = n.card_id
                  WHERE n.psa${g} > 0 AND o.psa${g} > 0
                    AND NOT EXISTS (SELECT 1 FROM temp._bad_grade bg WHERE bg.card_id = n.card_id AND bg.grade = '${g}')
                    ${sameSource}`);
        }
        upsert(`SELECT n.card_id, 'condition', n.condition, (n.usd - o.usd) / o.usd
                FROM price_by_condition n JOIN old.price_by_condition o
                  ON o.card_id = n.card_id AND o.condition = n.condition
                WHERE n.usd > 0 AND o.usd > 0
                  AND NOT EXISTS (SELECT 1 FROM temp._bad_condition bc
                                  WHERE bc.card_id = n.card_id AND bc.condition = n.condition)
                  ${sameSource}`);
        // Rule 2 — a modelled printing: ≥2 ranked conditions on each night that has the table.
        const modelled = (newHasMatrix
          ? "AND EXISTS (SELECT 1 FROM temp._ladder_new l WHERE l.card_id = n.card_id AND l.printing = n.printing AND l.n >= 2)" : "")
          + (oldHasMatrix
          ? " AND EXISTS (SELECT 1 FROM temp._ladder_old l WHERE l.card_id = n.card_id AND l.printing = n.printing AND l.n >= 2)" : "");
        upsert(`SELECT n.card_id, 'printing', n.printing, (n.usd - o.usd) / o.usd
                FROM price_by_variant n JOIN old.price_by_variant o
                  ON o.card_id = n.card_id AND o.printing = n.printing
                WHERE n.usd > 0 AND o.usd > 0 ${modelled} ${sameTop("n.printing")} ${topCellOk("n.printing")}
                  ${sameSource}`);
        // Matrix deltas: keyed "printing|condition" ('|' appears in neither PPT key set).
        // Guarded like the psa-column probe — artifacts published before the matrix feature
        // have no price_matrix table, and one missing table must not abort the window's
        // remaining upserts (they already ran) or log a scary failure for a normal rollout.
        if (newHasMatrix && oldHasMatrix) {
          upsert(`SELECT n.card_id, 'matrix', n.printing || '|' || n.condition, (n.usd - o.usd) / o.usd
                  FROM price_matrix n JOIN old.price_matrix o
                    ON o.card_id = n.card_id AND o.printing = n.printing AND o.condition = n.condition
                  WHERE n.usd > 0 AND o.usd > 0
                    AND NOT EXISTS (SELECT 1 FROM temp._bad_cell bc WHERE bc.card_id = n.card_id
                                    AND bc.printing = n.printing AND bc.condition = n.condition)
                    ${sameSource}`);
        }

        // Rule 3 — corroboration, over what rules 1, 2 and 4 let through for THIS window. Witnesses
        // are judged on those survivors, all decided before any is cleared, so two unwitnessed
        // jumps can't vouch for each other by order of evaluation.
        const c = lb.col;
        const witnessed = (scope: string) => `EXISTS (SELECT 1 FROM price_delta w WHERE w.card_id = d.card_id
            AND ${scope} AND w.${c} IS NOT NULL
            AND ((d.${c} > 0 AND w.${c} >= ${WITNESS_MOVE}) OR (d.${c} < 0 AND w.${c} <= -${WITNESS_MOVE}))
            AND ABS(d.${c}) <= ${MAX_OVER_WITNESS} * ABS(w.${c}))`;
        // Another condition of `printing` (an SQL expression), never the top cell the price quotes.
        const otherCondition = (printing: string) => `w.kind = 'matrix'
            AND substr(w.key, 1, length(${printing}) + 1) = ${printing} || '|'
            AND ${rank(`substr(w.key, length(${printing}) + 2)`)} IS NOT
                (SELECT l.top FROM temp._ladder_new l WHERE l.card_id = d.card_id AND l.printing = ${printing})`;
        db.exec(`
          DROP TABLE IF EXISTS temp._unwitnessed;
          CREATE TEMP TABLE _unwitnessed(card_id TEXT, kind TEXT, key TEXT, PRIMARY KEY(card_id, kind, key));
          INSERT INTO _unwitnessed SELECT d.card_id, d.kind, d.key FROM price_delta d
          WHERE d.${c} IS NOT NULL AND ABS(d.${c}) > ${CORROBORATE_ABOVE} AND NOT (
               (d.kind = 'matrix' AND ${witnessed(`w.kind = 'matrix' AND w.key != d.key
                  AND substr(w.key, 1, instr(w.key, '|')) = substr(d.key, 1, instr(d.key, '|'))`)})
            OR (d.kind = 'condition' AND ${witnessed("w.kind = 'condition' AND w.key != d.key")})
            OR (d.kind = 'psa' AND ${witnessed("w.kind = 'psa' AND w.key != d.key")})
            OR (d.kind = 'printing' AND ${witnessed(otherCondition("d.key"))})
            ${newLatest.has("raw_printing") ? `OR (d.kind = 'raw' AND ${witnessed(otherCondition(
              "(SELECT p.raw_printing FROM main.price_latest p WHERE p.card_id = d.card_id)"))})` : ""});
          UPDATE price_delta SET ${c} = NULL WHERE EXISTS (SELECT 1 FROM temp._unwitnessed u
            WHERE u.card_id = price_delta.card_id AND u.kind = price_delta.kind AND u.key = price_delta.key);`);
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
    // A row whose every window was cleared by rule 3 is no row at all.
    db.exec("DELETE FROM price_delta WHERE pct_1d IS NULL AND pct_7d IS NULL AND pct_30d IS NULL");
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
