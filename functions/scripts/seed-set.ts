/**
 * Polite one-set seed. Fetches a single set from the live TCGdex API
 * (~1 + N requests for an N-card set — e.g. cel25 ≈ 27) and builds+publishes
 * a real catalog artifact + manifest locally. RAW-ONLY: no PPT/graded fetch.
 *
 * Usage: npx tsx scripts/seed-set.ts [setId=cel25] [outDir=.seed-output]
 * Produces <outDir>/catalog/catalog-v1.sqlite.gz and <outDir>/catalog/manifest.json.
 */
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { TcgdexClient } from "../src/upstream/tcgdex";
import { buildCatalog } from "../src/pipeline/catalog";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { loadScenes } from "../src/pipeline/connectedArt";
import type { PptPrice } from "../src/upstream/ppt";

const setId = process.argv[2] ?? "cel25";
const outDir = process.argv[3] ?? join(__dirname, "../.seed-output");

class LocalStorage implements StoragePort {
  async save(path: string, data: Buffer, _contentType: string) {
    const full = join(outDir, path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, data);
    console.log(`  wrote ${path} (${data.length.toLocaleString()} bytes)`);
  }
}

async function main() {
  const tcgdex = new TcgdexClient();
  console.log(`[1] listing sets…`);
  const allSets = await tcgdex.listSets();
  const set = allSets.find((s) => s.id === setId);
  if (!set) throw new Error(`set "${setId}" not found among ${allSets.length} sets`);
  console.log(`    set: ${set.id} "${set.name}" (${set.serie}, released ${set.releaseDate}, total ${set.cardCountTotal})`);

  console.log(`[2] fetching cards for ${setId} (sequential, polite)…`);
  const cards = await tcgdex.getSetCards(setId);
  const withUsd = cards.filter((c) => c.rawUsd != null).length;
  const withEur = cards.filter((c) => c.rawEur != null).length;
  console.log(`    ${cards.length} cards · ${withUsd} with raw_usd · ${withEur} with raw_eur`);
  const sample = cards.find((c) => c.rawUsd != null) ?? cards[0];
  if (sample) console.log(`    sample: ${sample.id} "${sample.name}" hp=${sample.hp} usd=${sample.rawUsd} eur=${sample.rawEur}`);

  console.log(`[3] building catalog (raw-only; no graded/PPT)…`);
  const scenes = loadScenes(JSON.parse(readFileSync(join(__dirname, "../data/connected-art.json"), "utf8")));
  const asOf = new Date().toISOString().slice(0, 10);
  const dbPath = join(tmpdir(), `catalog-${setId}.sqlite`);
  buildCatalog({ sets: [set], cardsBySet: new Map([[setId, cards]]), prices: new Map<string, PptPrice>(), scenes, asOf, dexByCard: new Map(), pokemonNames: new Map() }, dbPath);

  console.log(`[4] publishing to ${outDir}/catalog/ …`);
  const manifest = await publishCatalog(dbPath, 1, new LocalStorage(), new Date());
  console.log(`\n✅ seeded ${setId}: manifest v${manifest.version}, ${manifest.sizeBytes.toLocaleString()} gz bytes, asOf ${asOf}`);
  console.log(`   sha256 ${manifest.sha256}`);
  console.log(`   artifacts: ${outDir}/catalog/{manifest.json, ${manifest.path.split("/").pop()}}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
