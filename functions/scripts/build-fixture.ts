import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { buildCatalog } from "../src/pipeline/catalog";
import type { TcgdexCard, TcgdexSet } from "../src/upstream/tcgdex";
import type { PptPrice } from "../src/upstream/ppt";

const sets: TcgdexSet[] = [
  // printed_total (203) intentionally differs from cardCountTotal (237): the identical-art
  // denominator tiebreaker uses printed_total when present, so this set exercises that path.
  { id: "swsh7", name: "Evolving Skies", releaseDate: "2021-08-27", cardCountTotal: 237, printedTotal: 203, serie: "Sword & Shield" },
  // printed_total == total here: the same-value case (no divergence to tiebreak on).
  { id: "sv1", name: "Scarlet & Violet", releaseDate: "2023-03-31", cardCountTotal: 198, printedTotal: 198, serie: "Scarlet & Violet" },
  // Promo set: numerator-only zero-padded numbers, no printed denominator.
  { id: "svp", name: "SV Black Star Promos", releaseDate: "2023-03-31", cardCountTotal: 100, printedTotal: null, serie: "Scarlet & Violet" },
];

const card = (p: Partial<TcgdexCard> & Pick<TcgdexCard, "id" | "localId" | "name">): TcgdexCard => ({
  hp: null, types: [], rarity: null, artist: null, text: "", imageBase: null,
  rawUsd: null, rawEur: null, ...p,
});

const cardsBySet = new Map<string, TcgdexCard[]>([
  ["swsh7", [
    card({ id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: 320, types: ["Dragon"], rarity: "Secret Rare",
      artist: "PLANETA Tsuji", text: "Draconic Zenith Once during your turn, you may draw 3 cards.",
      imageBase: "https://assets.tcgdex.net/en/swsh/swsh7/215", rawUsd: 92.5, rawEur: 85.0 }),
    card({ id: "swsh7-94", localId: "94", name: "Umbreon V", hp: 200, types: ["Darkness"], rarity: "Rare", artist: "5ban",
      rawUsd: 30.1, rawEur: 27.0 }),
    card({ id: "swsh7-12", localId: "12", name: "Metapod", hp: 80, types: ["Grass"],
      imageUrl: "https://tcgplayer-cdn.tcgplayer.com/product/fixture_in_800x800.jpg" }),
    // Alphanumeric promo number — exercises the promo-number narrowing path (CandidateIndex
    // must NOT collapse "TG20" to -1 via Int(c.number)).
    card({ id: "swsh7-TG20", localId: "TG20", name: "Charizard V", hp: 220, types: ["Fire"] }),
  ]],
  ["sv1", [
    card({ id: "sv1-1", localId: "1", name: "Sprigatito", hp: 70, types: ["Grass"], rawUsd: 0.2, rawEur: 0.18 }),
    card({ id: "sv1-25", localId: "25", name: "Pikachu", hp: 60, types: ["Lightning"], rawUsd: 0.4, rawEur: 0.35 }),
  ]],
  ["svp", [
    // Zero-padded promo number — exercises normalized number search ("25" must find it).
    card({ id: "svp-025", localId: "025", name: "Pikachu", hp: 60, types: ["Lightning"], rawUsd: 3.5 }),
  ]],
]);

const price = (tcgPlayerId: number, cardNumber: string, name: string, graded: Record<string, number> = {}): PptPrice =>
  ({ tcgPlayerId, setName: "fixture", cardNumber, name, raw: 0, graded });

const prices = new Map<string, PptPrice>([
  // psa8 intentionally absent while 7/9/10 are present — the Grade It interpolation gap case.
  ["swsh7-215", price(1, "215", "Rayquaza VMAX", { psa7: 90, psa9: 180, psa10: 505 })],
  ["swsh7-94", price(2, "94", "Umbreon V")],
  ["sv1-1", price(3, "1", "Sprigatito")],
  ["sv1-25", price(4, "25", "Pikachu", { psa10: 15 })],
]);

const scenes = [{ sceneId: "es-ray", title: "Rayquaza sky", cardIds: ["swsh7-215", "swsh7-94"] }];

const outDir = join(__dirname, "../../ios/TheTin/Tests/Fixtures");
mkdirSync(outDir, { recursive: true });
const out = join(outDir, "catalog-fixture.sqlite");
for (const f of [out, `${out}-wal`, `${out}-shm`]) if (existsSync(f)) rmSync(f);
// Synthetic identical-art twin pair for testing the twin→chooser + denominator gate — sv1-1/sv1-25
// don't actually share art; card_twin is just a lookup table, so this is fine for fixture purposes.
buildCatalog(
  { sets, cardsBySet, prices, scenes, asOf: "2026-07-04", dexByCard: new Map(), pokemonNames: new Map(), twins: [["sv1-1", "sv1-25"]] },
  out,
);

const db = new Database(out); // buildCatalog closes its handle before returning; reopen here
const insHist = db.prepare("INSERT INTO price_history VALUES (?,?,?)");
insHist.run("swsh7-215", "2026-01-05", 88.0);
insHist.run("swsh7-215", "2026-01-12", 90.5);
insHist.run("swsh7-215", "2026-01-19", 92.5);
db.close();

console.log(`fixture written: ${out}`);
