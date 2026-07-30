/**
 * The pipeline's card/set metadata contract.
 *
 * Lives in `src/` rather than beside `flatten-cards-db.ts`, which produces it, because
 * `src/pipeline/japanese.ts` produces it too — from the live API rather than from the offline
 * `cards-database` clone — and `src/` must not import from `scripts/` (tsc's rootDir, and the
 * right direction for the dependency anyway).
 */
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
  // --- non-English ingest (see src/pipeline/japanese.ts) -----------------------------------
  // English cards never set these; they take the tcgcsv/PPT price join and the assets.tcgdex.net
  // path rebuild unchanged. A card that arrives carrying its own price and image is one the
  // offline cards-database clone doesn't contain.
  /** Marks a card whose prices are EUR-only and converted to USD at build time. */
  lang?: "ja";
  /** Image URL as the API gave it, when there is no serie/set path to rebuild one from. */
  imageBase?: string | null;
  /** Cardmarket EUR trend, carried on the card because there is no cardmarket id to join on. */
  rawEur?: number | null;
}
