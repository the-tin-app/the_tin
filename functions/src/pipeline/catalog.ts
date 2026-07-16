import Database from "better-sqlite3";
import type { TcgdexCard, TcgdexSet } from "../upstream/tcgdex";
import type { PptPrice } from "../upstream/ppt";
import type { ArtScene } from "./connectedArt";

export interface CatalogInput {
  sets: TcgdexSet[];
  cardsBySet: Map<string, TcgdexCard[]>;
  prices: Map<string, PptPrice>;
  scenes: ArtScene[];
  asOf: string;
  dexByCard: Map<string, number[]>;
  pokemonNames: Map<number, string>;
  twins?: [string, string][];
}

const SCHEMA = `
CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT NOT NULL, release_date TEXT, total INTEGER NOT NULL, printed_total INTEGER, era TEXT, rep_card_id TEXT);
CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES set_info(id), number TEXT NOT NULL,
  name TEXT NOT NULL, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, image_url TEXT, tcgplayer_id INTEGER);
CREATE VIRTUAL TABLE card_text USING fts5(card_id UNINDEXED, name, body);
CREATE TABLE price_latest(card_id TEXT PRIMARY KEY REFERENCES card(id), raw_usd REAL, raw_eur REAL,
  psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT NOT NULL);
CREATE TABLE connected_art(scene_id TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'combined', title TEXT NOT NULL, card_id TEXT NOT NULL, position INTEGER NOT NULL,
  PRIMARY KEY(scene_id, card_id));
CREATE TABLE pokemon(dex_id INTEGER PRIMARY KEY, name TEXT NOT NULL, rep_card_id TEXT);
CREATE TABLE card_dex(card_id TEXT NOT NULL, dex_id INTEGER NOT NULL, PRIMARY KEY(card_id, dex_id));
CREATE TABLE price_history(card_id TEXT NOT NULL REFERENCES card(id), date TEXT NOT NULL, raw_usd REAL NOT NULL,
  PRIMARY KEY(card_id, date));
CREATE INDEX idx_card_dex_dex ON card_dex(dex_id);
CREATE INDEX idx_card_set ON card(set_id);
CREATE INDEX idx_card_tcgplayer ON card(tcgplayer_id);
CREATE INDEX idx_price_history_card ON price_history(card_id);
CREATE TABLE population(card_id TEXT NOT NULL REFERENCES card(id), grader TEXT NOT NULL, grade TEXT NOT NULL,
  count INTEGER, gem_rate REAL, total_population INTEGER, as_of TEXT NOT NULL,
  PRIMARY KEY(card_id, grader, grade));
CREATE TABLE graded_history(card_id TEXT NOT NULL REFERENCES card(id), grade TEXT NOT NULL, date TEXT NOT NULL,
  usd REAL NOT NULL, PRIMARY KEY(card_id, grade, date));
CREATE INDEX idx_population_card ON population(card_id);
CREATE INDEX idx_graded_history_card ON graded_history(card_id);
CREATE TABLE price_history_cond(card_id TEXT NOT NULL REFERENCES card(id), condition TEXT NOT NULL, date TEXT NOT NULL,
  raw_usd REAL NOT NULL, PRIMARY KEY(card_id, condition, date));
CREATE TABLE price_by_condition(card_id TEXT NOT NULL REFERENCES card(id), condition TEXT NOT NULL, usd REAL NOT NULL,
  as_of TEXT NOT NULL, PRIMARY KEY(card_id, condition));
CREATE INDEX idx_price_history_cond_card ON price_history_cond(card_id);
CREATE INDEX idx_price_by_condition_card ON price_by_condition(card_id);
CREATE TABLE price_by_variant(card_id TEXT NOT NULL REFERENCES card(id), printing TEXT NOT NULL, usd REAL NOT NULL,
  as_of TEXT NOT NULL, PRIMARY KEY(card_id, printing));
CREATE INDEX idx_price_by_variant_card ON price_by_variant(card_id);
CREATE TABLE card_twin(card_id TEXT NOT NULL, twin_id TEXT NOT NULL, PRIMARY KEY(card_id, twin_id));
CREATE TABLE sealed_product(tcgplayer_id INTEGER PRIMARY KEY, name TEXT NOT NULL, set_id TEXT, product_type TEXT,
  market_usd REAL, low_usd REAL, as_of TEXT);
CREATE INDEX idx_sealed_product_set ON sealed_product(set_id);
`;

export function pickRepresentative(
  cardIds: string[],
  prices: Map<string, { rawUsd: number | null; rawEur: number | null; priced?: boolean }>,
  cards: Map<string, { number: string; imageBase: string | null }>,
): string | null {
  let bestUsd: { id: string; v: number } | null = null;
  let bestEur: { id: string; v: number } | null = null;
  for (const id of cardIds) {
    const p = prices.get(id);
    if (p?.rawUsd != null && (!bestUsd || p.rawUsd > bestUsd.v)) bestUsd = { id, v: p.rawUsd };
    if (p?.rawEur != null && (!bestEur || p.rawEur > bestEur.v)) bestEur = { id, v: p.rawEur };
  }
  if (bestUsd) return bestUsd.id;
  if (bestEur) return bestEur.id;
  // Fallback for cards with no raw price: prefer one that still has SOME price (e.g. graded-only,
  // so it's in price_latest) over a genuinely unpriced sibling; then lowest card number with an image.
  const withImg = cardIds.filter((id) => cards.get(id)?.imageBase != null);
  const priced = withImg.filter((id) => prices.get(id)?.priced);
  const pool = priced.length ? priced : withImg;
  return pool.sort((a, b) => (parseInt(cards.get(a)!.number) || 0) - (parseInt(cards.get(b)!.number) || 0))[0] ?? null;
}

export function buildCatalog(input: CatalogInput, outPath: string): void {
  const db = new Database(outPath);
  db.pragma("journal_mode = WAL");
  db.exec(SCHEMA);

  const insSet = db.prepare("INSERT INTO set_info VALUES (?,?,?,?,?,?,?)");
  const insCard = db.prepare("INSERT INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?)");
  const insText = db.prepare("INSERT INTO card_text (card_id, name, body) VALUES (?,?,?)");
  const insPrice = db.prepare("INSERT INTO price_latest VALUES (?,?,?,?,?,?,?,?)");
  const insArt = db.prepare("INSERT INTO connected_art VALUES (?,?,?,?,?)");
  const insPokemon = db.prepare("INSERT INTO pokemon VALUES (?,?,?)");
  const insCardDex = db.prepare("INSERT INTO card_dex VALUES (?,?)");
  const insTwin = db.prepare("INSERT OR IGNORE INTO card_twin VALUES (?,?)");

  const allCardIds = new Set<string>();

  db.transaction(() => {
    // price/card lookup maps for representative selection — built as a no-DB-write pass so
    // set_info rows (which need rep_card_id) can be inserted before card rows, satisfying the
    // card.set_id -> set_info(id) foreign key (better-sqlite3 enforces FKs by default).
    const priceLookup = new Map<string, { rawUsd: number | null; rawEur: number | null; priced: boolean }>();
    const cardLookup = new Map<string, { number: string; imageBase: string | null }>();
    const cardIdsBySet = new Map<string, string[]>();
    const cardIdsByDex = new Map<number, string[]>();

    for (const [setId, cards] of input.cardsBySet) {
      for (const c of cards) {
        const g = input.prices.get(c.id)?.graded;
        const priced = c.rawUsd != null || c.rawEur != null ||
          g?.psa3 != null || g?.psa7 != null || g?.psa9 != null || g?.psa10 != null;
        priceLookup.set(c.id, { rawUsd: c.rawUsd, rawEur: c.rawEur, priced });
        cardLookup.set(c.id, { number: c.localId, imageBase: c.imageBase });
        (cardIdsBySet.get(setId) ?? cardIdsBySet.set(setId, []).get(setId)!).push(c.id);
        for (const dex of input.dexByCard.get(c.id) ?? []) {
          (cardIdsByDex.get(dex) ?? cardIdsByDex.set(dex, []).get(dex)!).push(c.id);
        }
      }
    }

    for (const s of input.sets) {
      insSet.run(s.id, s.name, s.releaseDate, s.cardCountTotal, s.printedTotal ?? null, s.serie, pickRepresentative(cardIdsBySet.get(s.id) ?? [], priceLookup, cardLookup));
    }

    for (const [setId, cards] of input.cardsBySet) {
      for (const c of cards) {
        allCardIds.add(c.id);
        const p = input.prices.get(c.id);
        const psa3 = p?.graded.psa3 ?? null, psa7 = p?.graded.psa7 ?? null,
              psa9 = p?.graded.psa9 ?? null, psa10 = p?.graded.psa10 ?? null;
        const hasPrice = c.rawUsd != null || c.rawEur != null || psa3 != null || psa7 != null || psa9 != null || psa10 != null;
        insCard.run(c.id, setId, c.localId, c.name, c.hp, c.types.join(","), c.rarity, c.artist, c.imageBase, c.imageUrl ?? null, p?.tcgPlayerId ?? null);
        insText.run(c.id, c.name, c.text);
        if (hasPrice) insPrice.run(c.id, c.rawUsd, c.rawEur, psa3, psa7, psa9, psa10, input.asOf);
        for (const dex of input.dexByCard.get(c.id) ?? []) insCardDex.run(c.id, dex);
      }
    }

    for (const [a, b] of input.twins ?? []) {
      if (allCardIds.has(a) && allCardIds.has(b)) { insTwin.run(a, b); insTwin.run(b, a); }
    }

    for (const [dex, ids] of cardIdsByDex) {
      const name = input.pokemonNames.get(dex) ?? `#${dex}`;
      insPokemon.run(dex, name, pickRepresentative(ids, priceLookup, cardLookup));
    }

    for (const scene of input.scenes) {
      scene.cardIds.forEach((cardId, i) => {
        if (allCardIds.has(cardId)) insArt.run(scene.sceneId, scene.kind ?? "combined", scene.title, cardId, i);
      });
    }
  })();

  db.close();
}
