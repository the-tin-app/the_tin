/**
 * Probe PPT coverage for the catalog's current gaps. LIVE — needs PPT_API_KEY.
 * Usage: PPT_API_KEY=... npx tsx scripts/probe-ppt-coverage.ts <catalog.sqlite> [outDir=.seed-output/coverage]
 */
import Database from "better-sqlite3";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PptClient, CreditBudget, parseCreditBudget, CreditBudgetExceeded } from "../src/upstream/ppt";
import { resolvePptSetName, PptSetInfo } from "../src/pipeline/ppt-setmap";
import { computeCoverage, OurCard } from "../src/pipeline/ppt-coverage";

const BASE = "https://www.pokemonpricetracker.com/api/v2";
// One-off diagnostic probe, so deliberately gentle: ~24 req/min via a fixed throttle. A
// Business-tier key allows far more (the nightly enrichment sweep paces itself with
// PPT_MINUTE_LIMIT, default 400/min), but a probe has no reason to go fast. PPT bans a key
// for 1 hour after too many rate-limited (429) responses in a 5-minute window, so the goal
// is to NEVER produce a 429 — not to recover from one.
const THROTTLE_MS = 2500;

// NOTE: we do NOT retry on 429/403. Retrying a rate-limited request sends another
// rate-limited request, which is exactly what triggers PPT's 1-hour key ban. The loop below
// stops the whole probe on the first 429/403 and writes a partial report.
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function fetchAllPptSets(key: string): Promise<PptSetInfo[]> {
  const out: PptSetInfo[] = [];
  const LIMIT = 100;
  // PPT /sets paginates with limit/offset — `page` is rejected (400) on the paid tier.
  for (let offset = 0; offset < 4000; offset += LIMIT) {
    const res = await fetch(`${BASE}/sets?limit=${LIMIT}&offset=${offset}`, { headers: { Authorization: `Bearer ${key}` } });
    if (!res.ok) throw new Error(`PPT sets ${res.status}`);
    const body: any = await res.json();
    const rows: any[] = body.data ?? [];
    if (rows.length === 0) break;
    for (const s of rows) out.push({ name: s.name, slug: s.tcgPlayerId, series: s.series, releaseDate: s.releaseDate ?? null });
    if (rows.length < LIMIT) break;
  }
  return out;
}

async function main() {
  const key = process.env.PPT_API_KEY;
  if (!key) throw new Error("PPT_API_KEY not set — activate the paid tier and export the key");
  const dbPath = process.argv[2];
  if (!dbPath) throw new Error("usage: probe-ppt-coverage.ts <catalog.sqlite> [outDir]");
  const outDir = process.argv[3] ?? join(__dirname, "../.seed-output/coverage");

  const db = new Database(dbPath, { readonly: true });
  // Gap sets: any set with a card missing an image or a price row.
  const gapSets = db.prepare(`
    SELECT s.id, s.name, s.release_date AS releaseDate
    FROM set_info s
    WHERE EXISTS (
      SELECT 1 FROM card c LEFT JOIN price_latest p ON p.card_id = c.id
      WHERE c.set_id = s.id AND (c.image_base IS NULL OR p.card_id IS NULL)
    )
    ORDER BY s.release_date DESC`).all() as { id: string; name: string; releaseDate: string | null }[];

  const cardStmt = db.prepare(`
    SELECT c.id, c.number AS localId, c.name,
           (c.image_base IS NOT NULL) AS hasImage,
           (p.card_id IS NOT NULL) AS hasPrice
    FROM card c LEFT JOIN price_latest p ON p.card_id = c.id
    WHERE c.set_id = ?`);

  const pptSets = await fetchAllPptSets(key);
  const budget = new CreditBudget(parseCreditBudget(process.env.PPT_DAILY_CREDIT_BUDGET, 20000));
  const client = new PptClient(key, budget);

  const rows: any[] = [];
  let truncated = false;
  for (const gs of gapSets) {
    const our: OurCard[] = (cardStmt.all(gs.id) as any[]).map((r) => ({
      id: r.id, localId: r.localId, name: r.name, hasImage: !!r.hasImage, hasPrice: !!r.hasPrice,
    }));
    const pptSet = resolvePptSetName({ id: gs.id, name: gs.name, releaseDate: gs.releaseDate }, pptSets);
    let cov = { matched: 0, imageFillable: 0, priceFillable: 0 };
    let fetchError: string | null = null;
    if (pptSet) {
      try {
        await sleep(THROTTLE_MS);
        const cards = await client.getSetCards(pptSet.name);
        cov = computeCoverage(our, cards);
      }
      catch (e) {
        const msg = (e as Error).message;
        if (e instanceof CreditBudgetExceeded) {
          console.error("PPT credit budget exhausted — stopping early; report is partial");
          truncated = true;
          break;
        }
        // A 429 (rate limit) or 403 (block) means STOP IMMEDIATELY — never retry, or we risk
        // a 1-hour key ban. Write what we have and exit.
        if (/PPT (429|403)/.test(msg)) {
          console.error(`⛔ PPT rate-limited/blocked (${msg}) — STOPPING to protect the key; report is partial`);
          truncated = true;
          break;
        }
        fetchError = msg;
        console.error(`  ${gs.id}: PPT fetch failed: ${fetchError}`);
      }
    }
    const missingImg = our.filter((c) => !c.hasImage).length;
    const missingPrice = our.filter((c) => !c.hasPrice).length;
    rows.push({ setId: gs.id, setName: gs.name, pptSetName: pptSet?.name ?? null,
      cards: our.length, missingImg, missingPrice, fetchError, ...cov });
    console.log(`  ${gs.id} "${gs.name}" -> ${pptSet?.name ?? "UNMATCHED"} | img ${cov.imageFillable}/${missingImg} · price ${cov.priceFillable}/${missingPrice}`);
  }
  db.close();

  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, "report.json"), JSON.stringify(rows, null, 2));
  const totImg = rows.reduce((a, r) => a + r.imageFillable, 0);
  const totPrice = rows.reduce((a, r) => a + r.priceFillable, 0);
  const unmatched = rows.filter((r) => r.pptSetName == null).length;
  const errored = rows.filter((r) => r.fetchError).length;
  const md = [
    `# PPT Coverage Probe`,
    ``,
    ...(truncated ? [`- ⚠️ PARTIAL: stopped early on credit budget`, ``] : []),
    `- Gap sets probed: **${rows.length}** (unmatched to PPT: **${unmatched}**, fetch errors: **${errored}**)`,
    `- Images fillable: **${totImg}** · Prices fillable: **${totPrice}** · credits spent: ${budget.spent}`,
    ``,
    `| set | PPT set | cards | img fill / missing | price fill / missing |`,
    `|---|---|---:|---:|---:|`,
    ...rows.map((r) => `| ${r.setId} ${r.setName} | ${r.pptSetName ?? "—"} | ${r.cards} | ${r.fetchError ? "ERR" : r.imageFillable + "/" + r.missingImg} | ${r.fetchError ? "ERR" : r.priceFillable + "/" + r.missingPrice} |`),
  ].join("\n");
  writeFileSync(join(outDir, "report.md"), md);
  const truncNote = truncated ? " ⚠️ PARTIAL: stopped early on credit budget" : "";
  console.log(`\n✅ report -> ${outDir}/report.md · images ${totImg} · prices ${totPrice} · ${unmatched} unmatched · ${errored} fetch errors · ${budget.spent} credits${truncNote}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
