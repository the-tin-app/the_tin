/**
 * Build / refresh the Japanese metadata cache — the offline equivalent, for Japanese, of what the
 * `cards-database` git clone gives English.
 *
 *   npx tsx scripts/fetch-ja-metadata.ts [outFile]
 *   outFile defaults to functions/.cache/ja-metadata.json
 *
 * ## Why this script exists at all
 *
 * English metadata costs the nightly ZERO API requests: `flatten-cards-db.ts` reads a local clone
 * of `tcgdex/cards-database`. That repo is international-only — its `neo1` carries en/fr/es/it/de
 * names and no `ja`, and the ~130 Japan-exclusive sets are not in it — so Japanese has to come
 * from the live API, one `/cards/{id}` request per card.
 *
 * A full sweep is ~16,400 requests (177 sets, 16,192 cards, measured 2026-07-29). Doing that every
 * night would be the single largest thing the nightly does, so it isn't done every night:
 *
 * **Steady state is ONE request.** `/sets` returns every set with its card count, so a run
 * compares those counts against the cache and re-fetches only sets that are new or have changed
 * size. A quiet night touches nothing. A new set costs that set. Only the first run pays in full.
 *
 * ⚠️ This is a card-count check, not a content check. A set whose card COUNT is unchanged is
 * assumed unchanged, so a corrected name or rarity on an existing card is not picked up. That is
 * the deliberate trade for a one-request nightly; `--force` re-fetches everything when it matters.
 *
 * ⚠️ Prices are NOT what this cache is for. It stores each card's EUR trend as it was on fetch
 * day, but `build-catalog` converts to USD with the CURRENT night's ECB rate, and a set that
 * hasn't changed size keeps a stale EUR figure until it does. Run with `--force` (or on a
 * schedule) if Japanese prices need to move. Recorded rather than hidden: a price that silently
 * never updates is worse than one that admits its date.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { TcgdexClient } from "../src/upstream/tcgdex";
import { toFlatSet, toFlatCard, jaSetId, type JaMetadata } from "../src/pipeline/japanese";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const outFile = resolve(process.argv.find((a) => !a.startsWith("--") && a.endsWith(".json"))
  ?? join(scriptDir, "../.cache/ja-metadata.json"));
const force = process.argv.includes("--force");

export async function refreshJaMetadata(
  client: TcgdexClient,
  previous: JaMetadata | null,
  opts: { force?: boolean; log?: (m: string) => void } = {},
): Promise<{ meta: JaMetadata; fetchedSets: string[]; reusedSets: number }> {
  const log = opts.log ?? (() => {});
  const remoteSets = await client.listSets();
  log(`[ja] ${remoteSets.length} sets upstream`);

  // Card counts from the cache, keyed by NAMESPACED set id — the cache only ever holds namespaced
  // ids, so comparing raw upstream ids against it would report every set as new, every night.
  const cachedCards = new Map<string, typeof previous extends null ? never : any>();
  const cachedCount = new Map<string, number>();
  for (const c of previous?.cards ?? []) {
    if (!cachedCards.has(c.setId)) cachedCards.set(c.setId, []);
    cachedCards.get(c.setId)!.push(c);
    cachedCount.set(c.setId, (cachedCount.get(c.setId) ?? 0) + 1);
  }

  const sets = remoteSets.map(toFlatSet);
  const cards: JaMetadata["cards"] = [];
  const fetchedSets: string[] = [];
  let reusedSets = 0;

  for (const set of remoteSets) {
    const nsId = jaSetId(set.id);
    const cached = cachedCards.get(nsId);
    // An upstream set with 0 cards is a placeholder, not a set we failed to read — fetching it
    // every night forever would be the one request that never pays off.
    const unchanged = !opts.force && cached && cachedCount.get(nsId) === set.cardCountTotal;
    if (unchanged) {
      cards.push(...cached);
      reusedSets++;
      continue;
    }
    if (set.cardCountTotal === 0) { reusedSets++; continue; }
    log(`[ja] fetching ${set.id} (${set.cardCountTotal} cards)`);
    // One failing set must not lose the other 176. Keep whatever the cache already had for it and
    // try again tomorrow — a partial Japanese catalogue is strictly better than no build.
    try {
      const fetched = await client.getSetCards(set.id);
      cards.push(...fetched.map((c) => toFlatCard(set.id, c)));
      fetchedSets.push(set.id);
    } catch (err) {
      log(`[ja] WARN ${set.id} failed (${String(err)}) — keeping ${cached?.length ?? 0} cached cards`);
      if (cached) cards.push(...cached);
    }
  }

  return {
    meta: { generatedAt: new Date().toISOString(), sets, cards },
    fetchedSets,
    reusedSets,
  };
}

export function readJaMetadata(path: string): JaMetadata | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as JaMetadata;
  } catch {
    return null;   // a corrupt cache is a full refetch, not a dead nightly
  }
}

async function main() {
  const previous = readJaMetadata(outFile);
  console.log(previous
    ? `[ja] cache: ${previous.cards.length} cards / ${previous.sets.length} sets`
    : "[ja] no cache — first run fetches every set (~16k requests, expect a long while)");

  const { meta, fetchedSets, reusedSets } = await refreshJaMetadata(
    new TcgdexClient(fetch, "ja"), previous, { force, log: (m) => console.log(m) });

  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, JSON.stringify(meta));
  console.log(`[ja] wrote ${outFile}: ${meta.cards.length} cards / ${meta.sets.length} sets`);
  console.log(`[ja] fetched ${fetchedSets.length} sets, reused ${reusedSets} from cache`);
}

// Only run when invoked directly — the exports above are imported by tests.
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
