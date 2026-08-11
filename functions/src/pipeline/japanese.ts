import type { FlatSet, FlatCard } from "./metadata";
import type { TcgdexSet, TcgdexCard } from "../upstream/tcgdex";
import { eurToUsd, type FxRate } from "../upstream/fx";

/**
 * Japanese ingest.
 *
 * Two things make this more than "run the pipeline against another URL":
 *
 * **1. Set ids genuinely collide.** Verified against the live API 2026-07-29: `neo1`–`neo4` exist
 * in BOTH languages as different sets — EN `neo1` is Neo Genesis (111 cards), JA `neo1` is
 * 金、銀、新世界へ… (96). Ingesting unnamespaced would overwrite the ENGLISH row and flip its
 * printed total from 111 to 96, silently breaking set-completion for every existing user
 * collecting Neo Genesis. That is a regression to shipped data, not a Japanese bug.
 *
 * Card ids happen not to collide today because the zero-padding differs (`neo1-1` vs `neo1-001`).
 * That is luck, not design, and is not relied on: **every** Japanese id is namespaced
 * unconditionally, including the ~173 sets that don't collide, because TCGdex adds sets over time
 * and a future collision must not be able to reach production.
 *
 * **2. English metadata is OFFLINE and Japanese cannot be.** `flatten-cards-db.ts` reads a local
 * clone of `tcgdex/cards-database`, which is international-only — its `neo1` carries en/fr/es/it/de
 * names and no `ja`, and the ~130 Japan-exclusive sets are absent entirely. So Japanese metadata
 * has to come from the live API, which is why it lands in its own incrementally-refreshed cache
 * (`scripts/fetch-ja-metadata.ts`) rather than being fetched on every nightly.
 */
export const JA_PREFIX = "ja-";

export function jaSetId(id: string): string {
  return id.startsWith(JA_PREFIX) ? id : `${JA_PREFIX}${id}`;
}

/**
 * Namespace a card id by its SET, not by string prefixing the whole id — `SV1a-001` becomes
 * `ja-SV1a-001`, which keeps `FlatCard.id === `${setId}-${localId}`` true, the invariant
 * `build-catalog` and every `card.set_id` join rely on.
 */
export function jaCardId(setId: string, localId: string): string {
  return `${jaSetId(setId)}-${localId}`;
}

export function isJapanese(id: string): boolean {
  return id.startsWith(JA_PREFIX);
}

/** Both languages' ids after namespacing, for the collision assertion below. */
export function collidingIds(englishIds: Iterable<string>, japaneseIds: Iterable<string>): string[] {
  const en = new Set(englishIds);
  return [...japaneseIds].filter((id) => en.has(id));
}

export interface JaMetadata {
  /** ISO timestamp of the last refresh — informational only. */
  generatedAt: string;
  sets: FlatSet[];
  cards: FlatCard[];
}

/** Namespaced `FlatSet`, in the exact shape `flatten-cards-db` emits for English. */
export function toFlatSet(set: TcgdexSet): FlatSet {
  return {
    id: jaSetId(set.id),
    name: set.name,
    releaseDate: set.releaseDate,
    serie: set.serie,
    official: set.cardCountTotal || null,
    printedTotal: set.printedTotal,
  };
}

/**
 * Namespaced `FlatCard`. Japanese cards carry NO TCGplayer ids — verified live: the `tcgplayer`
 * pricing block is present but null on every sample — so the tcgcsv/PPT join has nothing to match
 * and the price rides along on the card itself as `rawEur`.
 *
 * `lang: "ja"` is the marker `build-catalog` branches on. It is also the ONLY signal the app needs
 * to footnote a price as converted: every `ja-` card's USD is converted, with no exceptions, so no
 * per-row "converted" column exists or is needed.
 */
export function toFlatCard(setId: string, card: TcgdexCard): FlatCard {
  return {
    id: jaCardId(setId, card.localId),
    setId: jaSetId(setId),
    serieId: null,          // the image URL comes whole from the API, so no path to rebuild
    localId: card.localId,
    name: card.name,
    hp: card.hp,
    types: card.types,
    rarity: card.rarity,
    artist: card.artist,
    text: card.text,
    attacks: card.attacks ?? [],
    tcgplayerIds: [],
    tcgplayerByType: [],
    cardmarketIds: [],
    dexId: [],              // the JA card endpoint carries no dexId
    lang: "ja",
    imageBase: card.imageBase,
    rawEur: card.rawEur,
  };
}

/**
 * USD for a Japanese card: its EUR price at the night's ECB rate.
 *
 * Converted at BUILD time, never at fetch time — the metadata cache is incremental, so a set
 * fetched in March would otherwise keep March's rate forever while its neighbours moved.
 */
export function jaRawUsd(card: FlatCard, fx: FxRate): number | null {
  return eurToUsd(card.rawEur, fx);
}
