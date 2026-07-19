/**
 * Flatten the tcgdex/cards-database repo (English `data/`) into a single
 * normalized metadata JSON — the offline replacement for 23k live /cards/:id calls.
 *
 * RUN WITH BUN (fast TS dynamic import; ~10s for 23k cards):
 *   bun scripts/flatten-cards-db.ts [cardsDbDir] [outFile]
 * Defaults:
 *   cardsDbDir = functions/.cache/cards-database
 *   outFile    = functions/.cache/catalog-metadata.json
 *
 * Output shape (consumed by build-catalog.ts):
 *   { generatedAt, source, sets: FlatSet[], cards: FlatCard[] }
 *
 * No network, no native deps — pure local import + serialize.
 */
import { readdirSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// import.meta.dir is Bun-only; fall back to import.meta.url for Node-based
// runners (e.g. vitest workers) that import this module for its exports.
const scriptDir = (import.meta as any).dir ?? dirname(fileURLToPath(import.meta.url));
const cardsDbDir = resolve(process.argv[2] ?? join(scriptDir, "../.cache/cards-database"));
const outFile = resolve(process.argv[3] ?? join(scriptDir, "../.cache/catalog-metadata.json"));
const dataRoot = join(cardsDbDir, "data");

// Variant priority mirrors pickTcgplayerMarket(): normal → holo → reverse → other.
const VARIANT_ORDER = ["normal", "holo", "reverse", "metal", "lenticular"];

// TCGdex variant type → PPT/TCGplayer printing key. Unmapped types pass through verbatim —
// the app's CardVariant.matches() is substring-tolerant, so verbatim beats dropping.
const PPT_PRINTING_BY_TYPE: Record<string, string> = {
  normal: "Normal", holo: "Holofoil", reverse: "Reverse Holofoil", firstEdition: "1st Edition",
};
export function pptPrintingName(tcgdexType: string): string {
  return PPT_PRINTING_BY_TYPE[tcgdexType] ?? tcgdexType;
}

interface ThirdPartyRef { type: string; tcgplayer?: number; cardmarket?: number }

export interface FlatSet {
  id: string;
  name: string;
  releaseDate: string | null;
  serie: string | null; // era (serie english name)
  official: number | null;
  printedTotal: number | null;
}
export interface FlatCard {
  id: string; // `${setId}-${localId}`
  setId: string;
  serieId: string | null;
  localId: string;
  name: string;
  hp: number | null;
  types: string[];
  rarity: string | null;
  artist: string | null;
  text: string; // english ability+attack effects joined by \n
  attacks: { name: string; damage: string | null; cost: string[] }[];
  // ordered candidate ids (variant-priority) for the price joins
  tcgplayerIds: number[];
  // ordered [tcgdexVariantType, tcgPlayerId] pairs (same priority order as tcgplayerIds);
  // the card-level fallback ref carries type "card"
  tcgplayerByType: [string, number][];
  cardmarketIds: number[];
  dexId: number[];
}

function en<T = string>(field: any): T | null {
  if (field == null) return null;
  if (typeof field === "object") return (field.en ?? null) as T | null;
  return field as T;
}

/** Collect thirdParty refs from card-level + each variant, in priority order. */
export function collectThirdParty(card: any): { tcgplayer: number[]; cardmarket: number[]; tcgplayerByType: [string, number][] } {
  const refs: ThirdPartyRef[] = [];
  if (Array.isArray(card.variants)) {
    const sorted = [...card.variants].sort((a, b) => {
      const ia = VARIANT_ORDER.indexOf(a?.type); const ib = VARIANT_ORDER.indexOf(b?.type);
      return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
    });
    for (const v of sorted) if (v?.thirdParty) refs.push({ type: v.type, ...v.thirdParty });
  }
  if (card.thirdParty) refs.push({ type: "card", ...card.thirdParty }); // card-level as fallback
  const tcgplayer: number[] = [], cardmarket: number[] = [];
  const tcgplayerByType: [string, number][] = [];
  for (const r of refs) {
    if (typeof r.tcgplayer === "number" && !tcgplayer.includes(r.tcgplayer)) {
      tcgplayer.push(r.tcgplayer);
      tcgplayerByType.push([r.type, r.tcgplayer]);
    }
    if (typeof r.cardmarket === "number" && !cardmarket.includes(r.cardmarket)) cardmarket.push(r.cardmarket);
  }
  return { tcgplayer, cardmarket, tcgplayerByType };
}

export function dexIdsOf(card: any): number[] {
  return Array.isArray(card?.dexId) ? card.dexId.filter((n: unknown): n is number => typeof n === "number") : [];
}

/** English attack list (name + damage + energy cost) for the no-image placeholder. */
export function attacksOf(card: any): FlatCard["attacks"] {
  return (card.attacks ?? []).flatMap((a: any) => {
    const name = en(a?.name);
    if (!name) return [];
    return [{
      name,
      damage: a?.damage != null ? String(a.damage) : null,
      cost: Array.isArray(a?.cost) ? a.cost.filter((c: unknown): c is string => typeof c === "string") : [],
    }];
  });
}

export function effectText(card: any): string {
  const parts: string[] = [];
  for (const a of card.abilities ?? []) {
    const n = en(a?.name); if (n) parts.push(n);
    const e = en(a?.effect); if (e) parts.push(e);
  }
  for (const a of card.attacks ?? []) {
    const n = en(a?.name); if (n) parts.push(n);
    const e = en(a?.effect); if (e) parts.push(e);
  }
  return parts.join("\n");
}

async function main() {
  const series = readdirSync(dataRoot).filter((n) => {
    try { return statSync(join(dataRoot, n)).isDirectory(); } catch { return false; }
  });

  const sets: FlatSet[] = [];
  const cards: FlatCard[] = [];
  let skippedSets = 0, skippedCards = 0;
  const t0 = performance.now();

  for (const serieName of series) {
    const serieDir = join(dataRoot, serieName);
    for (const entry of readdirSync(serieDir)) {
      const setDir = join(serieDir, entry);
      let isDir = false;
      try { isDir = statSync(setDir).isDirectory(); } catch { /* noop */ }
      if (!isDir) continue;

      const setFile = join(serieDir, `${entry}.ts`);
      let setObj: any;
      try { setObj = (await import(setFile)).default; } catch { skippedSets++; continue; }
      const setName = en(setObj?.name);
      if (!setObj?.id || !setName) { skippedSets++; continue; } // French-only / malformed sets

      const serieId: string | null = setObj?.serie?.id ?? null;
      const era = en(setObj?.serie?.name) ?? serieName;
      const official = typeof setObj?.cardCount?.official === "number" ? setObj.cardCount.official
                     : typeof setObj?.cardCount?.total === "number" ? setObj.cardCount.total : null;
      const printedOfficial = typeof setObj?.cardCount?.official === "number" ? setObj.cardCount.official : null;

      let setCardCount = 0;
      const cardFiles = readdirSync(setDir).filter((f) => f.endsWith(".ts"));
      for (const f of cardFiles) {
        let cardObj: any;
        try { cardObj = (await import(join(setDir, f))).default; } catch { skippedCards++; continue; }
        const name = en(cardObj?.name);
        if (!name) { skippedCards++; continue; } // non-english card
        const localId = f.slice(0, f.lastIndexOf("."));
        const { tcgplayer, cardmarket, tcgplayerByType } = collectThirdParty(cardObj);
        cards.push({
          id: `${setObj.id}-${localId}`,
          setId: setObj.id,
          serieId,
          localId,
          name,
          hp: typeof cardObj.hp === "number" ? cardObj.hp : null,
          types: Array.isArray(cardObj.types) ? cardObj.types : [],
          rarity: en(cardObj.rarity),
          artist: cardObj.illustrator ?? null,
          text: effectText(cardObj),
          attacks: attacksOf(cardObj),
          tcgplayerIds: tcgplayer,
          tcgplayerByType,
          cardmarketIds: cardmarket,
          dexId: dexIdsOf(cardObj),
        });
        setCardCount++;
      }

      sets.push({
        id: setObj.id,
        name: setName,
        releaseDate: setObj?.releaseDate ?? null,
        serie: era,
        official: Math.max(official ?? 0, setCardCount) || null,
        printedTotal: printedOfficial,
      });
    }
  }

  const dt = performance.now() - t0;
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, JSON.stringify({
    generatedAt: new Date().toISOString(),
    source: "tcgdex/cards-database (data/, english)",
    sets, cards,
  }));

  const withTp = cards.filter((c) => c.tcgplayerIds.length).length;
  const withCm = cards.filter((c) => c.cardmarketIds.length).length;
  console.log(`flattened ${cards.length} cards across ${sets.length} sets in ${(dt / 1000).toFixed(1)}s`);
  console.log(`  skipped: ${skippedSets} sets, ${skippedCards} cards (no english name / unloadable)`);
  console.log(`  join keys: ${withTp} cards w/ tcgplayer id, ${withCm} cards w/ cardmarket id`);
  console.log(`  wrote ${outFile}`);
  const u = cards.find((c) => c.id === "swsh7-215");
  if (u) console.log(`  spot swsh7-215: "${u.name}" hp=${u.hp} tcgplayer=${JSON.stringify(u.tcgplayerIds)} cardmarket=${JSON.stringify(u.cardmarketIds)}`);
}

// Only run the pipeline when this file is the entry point (bun/node CLI),
// not when it's imported for its exports (e.g. by unit tests).
const isMain = (import.meta as any).main ?? (process.argv[1] != null && resolve(process.argv[1]) === fileURLToPath(import.meta.url));
if (isMain) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
