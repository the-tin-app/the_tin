/**
 * Build the FULL English Pokémon catalog artifact (offline, ~217 polite HTTP requests).
 *
 * Inputs (produced/fetched separately, all cached under functions/.cache/):
 *   - catalog-metadata.json   ← `bun scripts/flatten-cards-db.ts` (metadata + join keys)
 *   - feeds/datas.json        ← assets.tcgdex.net image manifest (1 req)
 *   - feeds/cardmarket-price_guide_6.json ← Cardmarket EUR bulk guide (1 req, version-guarded)
 *   - feeds/tcgcsv/{groupId}.json ← tcgcsv USD prices per group (~217 req, polite)
 *
 * Joins raw_usd (TCGplayer productId) + raw_eur (Cardmarket idProduct) onto every card,
 * then reuses buildCatalog()/publishCatalog() unchanged to emit the exact app artifact.
 * RAW-ONLY: prices=new Map() (no graded/PPT).
 *
 * Usage: npx tsx scripts/build-catalog.ts [version=2] [outDir=.seed-output]
 *
 * Hybrid export mode (new model): set EXPORT_DIR to a folder of saved PPT bulk-export CSVs
 * (cards/ebay/sealed/population-latest.csv, via scripts/probe-ppt-export.ts SAVE_DIR=…). Raw +
 * graded + sealed + population then come from those CSVs instead of the ~217-request tcgcsv sweep;
 * EUR (cardmarket) + images (tcgdex) are unchanged. Per-condition prices stay on the REST path.
 *   EXPORT_DIR=.export-cache npx tsx scripts/build-catalog.ts 8
 */
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { buildCatalog } from "../src/pipeline/catalog";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { loadScenes } from "../src/pipeline/connectedArt";
import type { TcgdexCard, TcgdexSet } from "../src/upstream/tcgdex";
import { PptClient, CreditBudget, parseCreditBudget } from "../src/upstream/ppt";
import type { PptPrice } from "../src/upstream/ppt";
import { resolvePptSetName } from "../src/pipeline/ppt-setmap";
import { computeFills } from "../src/pipeline/ppt-enrich";
import { synthesizeMissingCards, numberKeys, type TcgcsvProduct } from "../src/pipeline/tcgcsv-cards";
import type { FlatCard, FlatSet } from "./flatten-cards-db";
import { pptPrintingName } from "./flatten-cards-db";
import Database from "better-sqlite3";
import {
  parseCardsExport, parseEbayExport, parseSealedExport, parsePopulationExport, applyExport,
} from "../src/pipeline/ppt-export";

const version = Number(process.argv[2] ?? 2);
const outDir = process.argv[3] ?? join(__dirname, "../.seed-output");
// EXPORT_DIR=<dir> switches raw+graded+sealed+pop prices from tcgcsv → PPT bulk-export CSVs
// (cards/ebay/sealed/population-latest.csv). EUR (cardmarket) + images (tcgdex) stay as-is.
const exportDir = process.env.EXPORT_DIR || null;
const cacheDir = join(__dirname, "../.cache");
const feedsDir = join(cacheDir, "feeds");
const tcgcsvDir = join(feedsDir, "tcgcsv");
const UA = "HobbyTCG/1.0";
const TCGCSV_CATEGORY = 3; // Pokémon
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

class LocalStorage implements StoragePort {
  async save(path: string, data: Buffer, _contentType: string) {
    const full = join(outDir, path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, data);
    console.log(`  wrote ${path} (${data.length.toLocaleString()} bytes)`);
  }
}

async function fetchJson(url: string): Promise<any> {
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  if (!res.ok) throw new Error(`${res.status} for ${url}`);
  return res.json();
}
async function fetchText(url: string): Promise<string> {
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  if (!res.ok) throw new Error(`${res.status} for ${url}`);
  return res.text();
}

// ---- USD (tcgcsv): cached-once, polite refetch only when upstream last-updated changes ----
const SUBTYPE_RANK: Record<string, number> = { "Normal": 0, "Holofoil": 1, "Reverse Holofoil": 2 };
function subtypeRank(name?: string): number {
  return name && name in SUBTYPE_RANK ? SUBTYPE_RANK[name] : 9;
}

async function loadUsdMap(): Promise<Map<number, number>> {
  mkdirSync(tcgcsvDir, { recursive: true });
  const markerFile = join(tcgcsvDir, "last-updated.txt");
  const groupsFile = join(tcgcsvDir, "groups.json");

  const remoteUpdated = (await fetchText("https://tcgcsv.com/last-updated.txt")).trim();
  const cachedUpdated = existsSync(markerFile) ? readFileSync(markerFile, "utf8").trim() : "";
  const fresh = cachedUpdated === remoteUpdated && existsSync(groupsFile);
  console.log(`  tcgcsv last-updated=${remoteUpdated} (cache ${fresh ? "HIT — no refetch" : "MISS — will fetch missing groups"})`);

  let groups: any[];
  if (fresh) {
    groups = JSON.parse(readFileSync(groupsFile, "utf8")).results ?? [];
  } else {
    const g = await fetchJson(`https://tcgcsv.com/tcgplayer/${TCGCSV_CATEGORY}/groups`);
    writeFileSync(groupsFile, JSON.stringify(g));
    groups = g.results ?? [];
    await sleep(120);
  }

  const usd = new Map<number, number>();
  const bestRank = new Map<number, number>();
  let fetched = 0;
  for (const grp of groups) {
    const gid = grp.groupId;
    const file = join(tcgcsvDir, `${gid}.json`);
    let rows: any[];
    if (existsSync(file)) {
      rows = JSON.parse(readFileSync(file, "utf8")).results ?? [];
    } else {
      const data = await fetchJson(`https://tcgcsv.com/tcgplayer/${TCGCSV_CATEGORY}/${gid}/prices`);
      writeFileSync(file, JSON.stringify(data));
      rows = data.results ?? [];
      fetched++;
      await sleep(120); // politeness: > ~100ms between requests
    }
    for (const row of rows) {
      const pid = row.productId, mp = row.marketPrice;
      if (typeof pid !== "number" || typeof mp !== "number" || mp <= 0) continue;
      const rank = subtypeRank(row.subTypeName);
      if (!usd.has(pid) || rank < (bestRank.get(pid) ?? 99)) { usd.set(pid, mp); bestRank.set(pid, rank); }
    }
  }
  writeFileSync(markerFile, remoteUpdated);
  console.log(`  tcgcsv: ${groups.length} groups (${fetched} fetched now), ${usd.size.toLocaleString()} priced products`);
  return usd;
}

// ---- EUR (Cardmarket bulk price guide): 1 request, version-guarded ----
async function loadEurMap(): Promise<Map<number, number>> {
  const file = join(feedsDir, "cardmarket-price_guide_6.json");
  let data: any;
  if (existsSync(file)) {
    data = JSON.parse(readFileSync(file, "utf8"));
  } else {
    mkdirSync(feedsDir, { recursive: true });
    data = await fetchJson("https://downloads.s3.cardmarket.com/productCatalog/priceGuide/price_guide_6.json");
    writeFileSync(file, JSON.stringify(data));
  }
  if (data.version !== 1) throw new Error(`Cardmarket price guide version ${data.version} !== 1 — refusing (shape unverified)`);
  const eur = new Map<number, number>();
  for (const pg of data.priceGuides ?? []) {
    if (typeof pg.idProduct === "number" && typeof pg.trend === "number" && pg.trend > 0) eur.set(pg.idProduct, pg.trend);
  }
  console.log(`  cardmarket: version=${data.version} createdAt=${data.createdAt} · ${eur.size.toLocaleString()} priced products`);
  return eur;
}

// ---- Products (tcgcsv): per-group product lists, for cards TCGdex doesn't have ----
// Same cache discipline as the price sweep, but a separate marker: product lists change far
// less often than prices, and the two sweeps must not invalidate each other. Runs in BOTH
// modes — export mode skips the PRICE sweep, but a missing card is missing either way.
async function loadProductsByGroup(): Promise<{ groupId: number; products: TcgcsvProduct[] }[]> {
  mkdirSync(tcgcsvDir, { recursive: true });
  const markerFile = join(tcgcsvDir, "products-last-updated.txt");
  const groupsFile = join(tcgcsvDir, "groups.json");

  const remoteUpdated = (await fetchText("https://tcgcsv.com/last-updated.txt")).trim();
  const cachedUpdated = existsSync(markerFile) ? readFileSync(markerFile, "utf8").trim() : "";
  const fresh = cachedUpdated === remoteUpdated;

  let groups: any[];
  if (fresh && existsSync(groupsFile)) {
    groups = JSON.parse(readFileSync(groupsFile, "utf8")).results ?? [];
  } else {
    const g = await fetchJson(`https://tcgcsv.com/tcgplayer/${TCGCSV_CATEGORY}/groups`);
    writeFileSync(groupsFile, JSON.stringify(g));
    groups = g.results ?? [];
    await sleep(120);
  }

  const out: { groupId: number; products: TcgcsvProduct[] }[] = [];
  let fetched = 0, failed = 0;
  for (const grp of groups) {
    const gid = grp.groupId;
    const file = join(tcgcsvDir, `products-${gid}.json`);
    let results: any[];
    if (fresh && existsSync(file)) {
      results = JSON.parse(readFileSync(file, "utf8")).results ?? [];
    } else {
      try {
        const data = await fetchJson(`https://tcgcsv.com/tcgplayer/${TCGCSV_CATEGORY}/${gid}/products`);
        writeFileSync(file, JSON.stringify(data));
        results = data.results ?? [];
        fetched++;
      } catch (e) {
        // One unreachable group must not fail the build — it only costs that group's new cards.
        console.error(`  products fetch failed for group ${gid}: ${(e as Error).message}`);
        failed++;
        results = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")).results ?? [] : [];
      }
      await sleep(120); // politeness, same as the price sweep
    }
    out.push({ groupId: gid, products: results });
  }
  // Only mark the cache good when EVERY group came back. Writing the marker after a partial
  // sweep would freeze a transient 5xx in as an empty group until tcgcsv's last-updated moves —
  // a set would quietly stop gaining cards and nothing in tomorrow's log would say why.
  if (failed === 0) writeFileSync(markerFile, remoteUpdated);
  else console.log(`  tcgcsv products: ${failed} group(s) failed — NOT marking cache fresh, next run refetches`);
  console.log(`  tcgcsv products: ${groups.length} groups (${fetched} fetched now, ${failed} failed)`);
  return out;
}

// ---- Images (datas.json): 1 request, existence manifest ----
async function loadImageManifest(): Promise<any> {
  const file = join(feedsDir, "datas.json");
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8"));
  mkdirSync(feedsDir, { recursive: true });
  const data = await fetchJson("https://assets.tcgdex.net/datas.json");
  writeFileSync(file, JSON.stringify(data));
  return data;
}

function pickPrice(ids: number[], map: Map<number, number>): number | null {
  for (const id of ids) { const v = map.get(id); if (typeof v === "number") return v; }
  return null;
}

async function main() {
  const metaFile = join(cacheDir, "catalog-metadata.json");
  if (!existsSync(metaFile)) throw new Error(`missing ${metaFile} — run: bun scripts/flatten-cards-db.ts`);
  const meta: { sets: FlatSet[]; cards: FlatCard[] } = JSON.parse(readFileSync(metaFile, "utf8"));
  console.log(`[1] loaded metadata: ${meta.cards.length} cards / ${meta.sets.length} sets`);

  const pokedex: Record<string, string> = JSON.parse(readFileSync(join(__dirname, "../data/pokedex.json"), "utf8"));
  const pokemonNames = new Map<number, string>(Object.entries(pokedex).map(([k, v]) => [Number(k), v]));

  console.log(`[2] loading price + image feeds…${exportDir ? " (raw/graded/sealed/pop from PPT export)" : ""}`);
  // Export mode: raw USD comes from the PPT cards export (applied after buildCatalog), so skip the
  // ~217-request tcgcsv sweep entirely. EUR + images still load from the cached bulk feeds.
  const usd = exportDir ? new Map<number, number>() : await loadUsdMap();
  const [eur, datas] = [await loadEurMap(), await loadImageManifest()];
  const enImages = datas.en ?? {};

  // [2b] Cards TCGdex has never published. The card universe was TCGdex-only, so a card it
  // lacks could never appear however well-priced it was upstream — that is how MEP 046-054
  // stayed missing while TCGplayer had them. Additive only: nothing existing is touched.
  console.log(`[2b] checking tcgcsv for cards TCGdex doesn't have…`);
  try {
    const setByTcgplayerId = new Map<number, string>();
    for (const c of meta.cards) for (const t of c.tcgplayerIds) if (!setByTcgplayerId.has(t)) setByTcgplayerId.set(t, c.setId);
    const numbersBySet = new Map<string, Set<string>>();
    for (const c of meta.cards) {
      if (!numbersBySet.has(c.setId)) numbersBySet.set(c.setId, new Set());
      for (const k of numberKeys(c.localId)) numbersBySet.get(c.setId)!.add(k);
    }
    const setTotals = new Map(meta.sets.map((s) => [s.id, { total: s.official, printedTotal: s.printedTotal }]));
    const dexByName = new Map<string, number>();
    for (const [id, name] of pokemonNames) if (!dexByName.has(name.toLowerCase())) dexByName.set(name.toLowerCase(), id);

    const result = synthesizeMissingCards({
      groups: await loadProductsByGroup(), setByTcgplayerId, numbersBySet, setTotals, dexByName,
    });
    const { cards: added, addedBySet, skippedForeignDenominator } = result;
    meta.cards.push(...added);
    // The set's own total came from the same stale TCGdex record, so it can now under-count
    // what the set holds — the app would render "63 / 60". Raise it to what we actually have.
    const countBySet = new Map<string, number>();
    for (const c of meta.cards) countBySet.set(c.setId, (countBySet.get(c.setId) ?? 0) + 1);
    for (const s of meta.sets) {
      const n = countBySet.get(s.id) ?? 0;
      if (n > (s.official ?? 0)) s.official = n;
    }
    // Every decision goes to a sidecar next to the artifact. If a card is wrong or missing
    // tomorrow, this answers "which group claimed that set, on how much evidence, and what
    // was rejected" WITHOUT re-running a ~217-request sweep or guessing from the log.
    // NOT outDir: the nightly runs with --rm and does not mount .seed-output, so a sidecar
    // written there is destroyed the moment the run ends — which is exactly when it is wanted.
    // .cache IS a persistent docker volume (catalog-pipeline-cache), so it survives.
    mkdirSync(cacheDir, { recursive: true });
    const sidecar = join(cacheDir, `tcgcsv-fill-v${version}.json`);
    writeFileSync(sidecar, JSON.stringify({
      generatedAt: new Date().toISOString(),
      version,
      summary: {
        added: added.length,
        sets: Object.fromEntries([...addedBySet].sort((a, b) => b[1] - a[1])),
        skippedForeignDenominator,
        groupsAccepted: result.decisions.filter((d) => !d.rejected).length,
        groupsRejected: result.decisions.filter((d) => d.rejected).length,
      },
      cards: added.map((c) => ({
        id: c.id, name: c.name, localId: c.localId, setId: c.setId,
        tcgplayerId: c.tcgplayerIds[0], hp: c.hp, types: c.types, rarity: c.rarity,
        attacks: c.attacks.map((a) => a.name), dexId: c.dexId,
      })),
      groupDecisions: result.decisions.sort((a, b) => b.matched - a.matched),
      foreignDenominatorRejects: result.rejects,
    }, null, 1));

    console.log(`[tcgcsv-fill] +${added.length} cards across ${addedBySet.size} sets`);
    for (const [setId, n] of [...addedBySet].sort((a, b) => b[1] - a[1])) console.log(`[tcgcsv-fill]   ${setId}: +${n}`);
    for (const c of added) console.log(`[tcgcsv-fill]   card ${c.id} "${c.name}" tcgplayer=${c.tcgplayerIds[0]}`);
    console.log(`[tcgcsv-fill] groups: ${result.decisions.filter((d) => !d.rejected).length} accepted, `
      + `${result.decisions.filter((d) => d.rejected).length} rejected `
      + `(${result.decisions.filter((d) => d.rejected === "too-few-matches").length} too-few-matches, `
      + `${result.decisions.filter((d) => d.rejected === "ambiguous").length} ambiguous)`);
    console.log(`[tcgcsv-fill] ${skippedForeignDenominator} products skipped: printed denominator belongs to another set`);
    console.log(`[tcgcsv-fill] full decision log: ${sidecar}`);
    // A sudden jump means an upstream shape change, not 400 new Pokémon cards. Loud, not fatal:
    // the guards are conservative and a wrong SKIP is cheaper than a wrong PUBLISH.
    if (added.length > 200) console.log(`[tcgcsv-fill] ⚠️ UNUSUALLY LARGE (${added.length}) — expected ~22; inspect ${sidecar} before trusting this catalog`);
  } catch (e) {
    // Best-effort, exactly like PPT enrichment: a tcgcsv outage must not stop the nightly.
    console.error(`⚠️ tcgcsv card fill failed (${(e as Error).message}) — publishing without it`);
  }

  const dexByCard = new Map<string, number[]>(meta.cards.map((c) => [c.id, c.dexId ?? []]));

  console.log(`[3] assembling catalog input (joining prices + images)…`);
  const sets: TcgdexSet[] = meta.sets.map((s) => ({
    id: s.id, name: s.name, releaseDate: s.releaseDate,
    cardCountTotal: s.official ?? 0, printedTotal: s.printedTotal ?? null, serie: s.serie,
  }));

  const cardsBySet = new Map<string, TcgdexCard[]>();
  let withUsd = 0, withEur = 0, withImg = 0;
  for (const c of meta.cards) {
    const rawUsd = pickPrice(c.tcgplayerIds, usd);
    const rawEur = pickPrice(c.cardmarketIds, eur);
    const imgExists = c.serieId ? Boolean(enImages?.[c.serieId]?.[c.setId]?.[c.localId]) : false;
    const imageBase = imgExists ? `https://assets.tcgdex.net/en/${c.serieId}/${c.setId}/${c.localId}` : null;
    if (rawUsd != null) withUsd++;
    if (rawEur != null) withEur++;
    if (imageBase) withImg++;
    const card: TcgdexCard = {
      id: c.id, localId: c.localId, name: c.name, hp: c.hp,
      types: c.types, rarity: c.rarity, artist: c.artist, text: c.text,
      attacks: c.attacks ?? [], // pre-attacks metadata JSON lacks the field
      imageBase, rawUsd, rawEur,
    };
    if (!cardsBySet.has(c.setId)) cardsBySet.set(c.setId, []);
    cardsBySet.get(c.setId)!.push(card);
  }

  const pptKey = process.env.PPT_API_KEY;
  if (pptKey) {
    try {
      console.log(`[3b] PPT enrichment: filling gap images + prices…`);
      const client = new PptClient(pptKey, new CreditBudget(parseCreditBudget(process.env.PPT_DAILY_CREDIT_BUDGET, 20000)));
      const pptSets = await client.getAllSets();
      let imgFilled = 0, priceFilled = 0, setsDone = 0, setsSkipped = 0;

      // Resumable: persist done-sets + fills to sidecars so a killed/timed-out run resumes without
      // re-spending PPT credits (the ~48-set sweep is PPT-paced and can exceed one run's time limit).
      const doneFile = join(cacheDir, `enrich-v${version}-done.json`);
      const fillsFile = join(cacheDir, `enrich-v${version}-fills.json`);
      const doneSets = new Set<string>(existsSync(doneFile) ? JSON.parse(readFileSync(doneFile, "utf8")) : []);
      const savedFills: Record<string, { imageUrl?: string; rawUsd?: number }> =
        existsSync(fillsFile) ? JSON.parse(readFileSync(fillsFile, "utf8")) : {};
      // Re-apply previously-recorded enrichment fills onto the freshly-built catalog.
      for (const cs of cardsBySet.values()) for (const c of cs) {
        const f = savedFills[c.id];
        if (!f) continue;
        if (f.imageUrl && c.imageBase == null) c.imageUrl = f.imageUrl;
        if (f.rawUsd != null && c.rawUsd == null) c.rawUsd = f.rawUsd;
      }
      if (doneSets.size) console.log(`  resuming: ${doneSets.size} sets already enriched (skipping their PPT calls)`);

      for (const [setId, cards] of cardsBySet) {
        // Plan 2b scope: the ~48 special sets MISSING IMAGES (promos, McDonald's, kits, galleries,
        // shiny vault, etc.). Filter on image gaps only — a matched card also gets its price filled
        // (computeFills returns both). Main-set price-only gaps are intentionally out of scope here
        // (they'd balloon this into a ~200-set, ~1h PPT sweep).
        const gaps = cards.filter((c) => c.imageBase == null);
        if (gaps.length === 0) continue;
        if (doneSets.has(setId)) continue; // enriched in a prior run (fills already re-applied above)
        const setMeta = meta.sets.find((s) => s.id === setId);
        const pptSet = resolvePptSetName({ id: setId, name: setMeta?.name ?? "", releaseDate: setMeta?.releaseDate ?? null }, pptSets);
        if (!pptSet) { setsSkipped++; continue; }

        let pptCards;
        try { pptCards = await client.getSetCards(pptSet.name); }
        catch (e) {
          // Rate-limit/other error: PptClient already honored Retry-After. Do NOT loop; log and stop
          // enriching (a partial-but-valid catalog still publishes).
          console.error(`  ⛔ stopping enrichment at ${setId}: ${(e as Error).message}`);
          break;
        }
        const fills = computeFills(
          gaps.map((c) => ({ id: c.id, localId: c.localId, name: c.name, hasImage: c.imageBase != null, hasPrice: c.rawUsd != null || c.rawEur != null })),
          pptCards,
        );
        // Prices + image URLs both fill in-memory. PPT hands us a PUBLIC tcgplayer-cdn URL —
        // store it directly (no self-hosting/mirror; sealed products hotlink the same CDN).
        for (const c of gaps) {
          const fill = fills.get(c.id);
          if (!fill) continue;
          if (fill.rawUsd != null && c.rawUsd == null) { c.rawUsd = fill.rawUsd; priceFilled++; }
          if (fill.imageUrl && c.imageBase == null) { c.imageUrl = fill.imageUrl; imgFilled++; }
        }
        // Record this set's fills + mark done — durable resume point (persisted after each set).
        for (const c of gaps) {
          const rec: { imageUrl?: string; rawUsd?: number } = {};
          if (c.imageUrl != null && c.imageBase == null) rec.imageUrl = c.imageUrl;
          const fill = fills.get(c.id);
          if (fill?.rawUsd != null) rec.rawUsd = fill.rawUsd;
          if (rec.imageUrl || rec.rawUsd != null) savedFills[c.id] = rec;
        }
        doneSets.add(setId);
        writeFileSync(fillsFile, JSON.stringify(savedFills));
        writeFileSync(doneFile, JSON.stringify([...doneSets]));
        setsDone++;
        console.log(`  [${setsDone}] ${setId} (${pptSet.name}): ${imgFilled} imgs · ${priceFilled} prices (this run)`);
      }
      console.log(`  PPT enrichment: ${imgFilled} image URLs · ${priceFilled} prices filled · ${setsDone} sets · ${setsSkipped} unmapped`);
    } catch (e) {
      // Enrichment is best-effort: any failure here (including getAllSets()) must not abort the
      // build. Log and fall through to publish the raw catalog without enrichment.
      console.error(`⚠️ PPT enrichment failed (${(e as Error).message}) — publishing raw catalog without enrichment`);
    }
  }

  const scenes = loadScenes(JSON.parse(readFileSync(join(__dirname, "../data/connected-art.json"), "utf8")));
  const asOf = new Date().toISOString().slice(0, 10);
  // Export mode writes the raw sqlite to a PREDICTABLE path so the hybrid condition/graded/pop
  // enrichment (fill-overnight.ts) can run on it next: `fill-overnight.ts <dbPath> <version> <outDir>`.
  const dbPath = exportDir ? join(outDir, `catalog-v${version}.sqlite`) : join(tmpdir(), `catalog-full-v${version}.sqlite`);
  if (exportDir) mkdirSync(outDir, { recursive: true });
  // ⚠️ `card_twin` was 0 rows in every published catalog for months, and the reason is entirely
  // here. It matters because the scanner's twin guard withholds a lock when two identical-art
  // reprints are both in the candidate pool, and with no rows it never fired.
  //
  // ⚠️ It is NOT a general explanation for wrong locks, and saying so was an overreach corrected by
  // Tomas on 2026-08-07: the single wrong lock in the 415-cell measured fixture set was a twin case
  // (`base1-2`/`base4-2` answered as `cel25cc-CC001`), but the wrong locks he saw on a real device
  // were plainly wrong cards, not paired art. Those remain unexplained; this fixes one specific
  // failure mode and no others. This used to default to `../fingerprint/.fp-output/twins.json`, which is (a) gitignored
  // and (b) OUTSIDE the Docker build context — the image is built from `functions/`, so `../` does
  // not exist in it at all. `existsSync` was therefore false on every nightly, `twins` was `[]`, and
  // the pipeline logged `twins=0` while everything downstream looked correct. The code was written,
  // the pairs were computed, and the two never met.
  //
  // So the pairs are checked in beside the pipeline that consumes them. They are derived data, but
  // they change only when the catalog gains a new identical-art reprint, and regenerating them needs
  // the ~23k-image cache — which is exactly the kind of artifact that belongs in the repo rather than
  // on one laptop. Regenerate with `fingerprint/scripts/build_twins.py`.
  const twinsPath = process.env.TWINS_JSON
    ?? [join(__dirname, "..", "data", "card-twins.json"),
        "../fingerprint/.fp-output/twins.json"].find(existsSync)
    ?? "";
  const twins: [string, string][] = twinsPath && existsSync(twinsPath)
    ? JSON.parse(readFileSync(twinsPath, "utf8"))
    : [];
  // ⚠️ Loud, not silent. A twins=0 line is indistinguishable from "this catalog has no reprints",
  // which is how this went unnoticed — the number was printed and nobody had a reason to doubt it.
  if (twins.length === 0) {
    console.warn(`[4] ⚠️ NO card_twin pairs (looked at ${twinsPath || "nothing"}). The scanner's `
      + `twin guard will be inert, so two identical-art reprints in one candidate pool can lock `
      + `confidently on either. See functions/data/card-twins.json.`);
  }
  console.log(`[4] building SQLite (raw-only; no graded/PPT)… twins=${twins.length} from ${twinsPath}`);
  // buildCatalog does CREATE TABLE (no IF NOT EXISTS) — clear any prior DB at the predictable
  // export path so a re-run (or the nightly container) starts fresh instead of colliding.
  for (const suffix of ["", "-wal", "-shm", "-journal"]) rmSync(`${dbPath}${suffix}`, { force: true });
  buildCatalog({ sets, cardsBySet, prices: new Map<string, PptPrice>(), scenes, asOf, dexByCard, pokemonNames, twins }, dbPath);

  let exportSpot: { rawUsd: number | null; rawEur: number | null } | null = null;
  if (exportDir) {
    console.log(`[4b] applying PPT bulk-export prices from ${exportDir}/ …`);
    // Match on EVERY printing SKU of each card (a card can carry several tcgPlayerIds).
    const idByTcg = new Map<number, string>();
    for (const c of meta.cards) for (const t of c.tcgplayerIds) if (!idByTcg.has(t)) idByTcg.set(t, c.id);

    // tcgPlayerId → printing label + per-card priority (index in the variant-priority order),
    // so applyExport can pick the primary printing deterministically and label graded rows.
    const skuMeta = new Map<number, { printing: string; priority: number }>();
    for (const c of meta.cards) {
      (c.tcgplayerByType ?? []).forEach(([type, tcg], i) => {
        if (!skuMeta.has(tcg)) skuMeta.set(tcg, { printing: pptPrintingName(type), priority: i });
      });
    }

    const db = new Database(dbPath);
    try {
      // Stamp each card's primary (first) SKU into card.tcgplayer_id for the app + DB-based joins.
      const upTcg = db.prepare("UPDATE card SET tcgplayer_id = ? WHERE id = ?");
      db.transaction(() => {
        for (const c of meta.cards) if (c.tcgplayerIds[0] != null) upTcg.run(c.tcgplayerIds[0], c.id);
      })();

      const readCsv = (name: string) => {
        const p = join(exportDir, name);
        return existsSync(p) ? readFileSync(p, "utf8") : null;
      };
      const cardsCsv = readCsv("cards-latest.csv");
      const ebayCsv = readCsv("ebay-latest.csv");
      const sealedCsv = readCsv("sealed-latest.csv");
      const popCsv = readCsv("population-latest.csv");
      console.log(`  csvs present: cards=${!!cardsCsv} ebay=${!!ebayCsv} sealed=${!!sealedCsv} population=${!!popCsv}`);

      const stats = applyExport(db, {
        cards: cardsCsv ? parseCardsExport(cardsCsv) : undefined,
        ebay: ebayCsv ? parseEbayExport(ebayCsv) : undefined,
        sealed: sealedCsv ? parseSealedExport(sealedCsv) : undefined,
        population: popCsv ? parsePopulationExport(popCsv) : undefined,
        asOf,
      }, idByTcg, skuMeta);
      console.log(`  applied: ${stats.rawRows} raw cards · ${stats.gradedRows} graded · ${stats.gradedPrintingRows} graded-by-printing · ${stats.sealedRows} sealed · ${stats.popRows} pop · ${stats.unmatched} unmatched export rows`);
      // The coverage/spot summary below is computed from the in-memory join, where USD is always
      // null in export mode (prices land only in the DB via applyExport). Read the true count +
      // spot back from the DB so the summary reflects what actually shipped, not a false 0.
      withUsd = (db.prepare("SELECT COUNT(raw_usd) AS n FROM price_latest").get() as { n: number }).n;
      exportSpot = db.prepare("SELECT raw_usd AS rawUsd, raw_eur AS rawEur FROM price_latest WHERE card_id = 'swsh7-215'").get() as { rawUsd: number | null; rawEur: number | null } | undefined ?? null;
    } finally {
      db.close();
    }
    // NOTE(hybrid): per-condition (NM/LP/MP) + EUR-from-PPT are NOT in the export — run the
    // existing REST enrichment (overnight-sweep) as the hybrid half to fill price_by_condition.
  }

  console.log(`[5] publishing v${version} to ${outDir}/catalog/ …`);
  const manifest = await publishCatalog(dbPath, version, new LocalStorage(), new Date());

  console.log(`\n✅ full catalog v${manifest.version}: ${meta.cards.length.toLocaleString()} cards · ${sets.length} sets`);
  console.log(`   coverage: ${withUsd.toLocaleString()} raw_usd · ${withEur.toLocaleString()} raw_eur · ${withImg.toLocaleString()} images`);
  const dexCards = meta.cards.filter((c) => (c.dexId ?? []).length > 0).length;
  const species = new Set(meta.cards.flatMap((c) => c.dexId ?? [])).size;
  console.log(`   pokédex: ${dexCards.toLocaleString()} cards with dexId · ${species} distinct species`);
  console.log(`   artifact: ${manifest.sizeBytes.toLocaleString()} gz bytes · sha256 ${manifest.sha256}`);
  console.log(`   asOf ${asOf} · files: ${outDir}/catalog/{manifest.json, ${manifest.path.split("/").pop()}}`);
  const u = cardsBySet.get("swsh7")?.find((c) => c.id === "swsh7-215");
  // In export mode read the spot price from the DB (in-memory usd is null there); eur/img in-memory are correct.
  const spotUsd = exportSpot ? exportSpot.rawUsd : u?.rawUsd;
  if (u) console.log(`   spot swsh7-215 "${u.name}": usd=${spotUsd} eur=${u.rawEur} img=${u.imageBase ? "yes" : "no"}`);
  if (exportDir) {
    console.log(`\n   raw sqlite: ${dbPath}`);
    console.log(`   → enrich condition/graded/pop (hybrid): PPT_API_KEY=$PPT_PAID npx tsx scripts/fill-overnight.ts ${dbPath} ${version} ${outDir}`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
