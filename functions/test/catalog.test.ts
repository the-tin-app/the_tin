import { describe, it, expect, beforeAll } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildCatalog, pickRepresentative } from "../src/pipeline/catalog";
import type { TcgdexCard, TcgdexSet } from "../src/upstream/tcgdex";
import type { PptPrice } from "../src/upstream/ppt";

const sets: TcgdexSet[] = [{ id: "swsh7", name: "Evolving Skies", releaseDate: "2021-08-27", cardCountTotal: 237, printedTotal: 203, serie: "Sword & Shield" }];
const cards: TcgdexCard[] = [
  { id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: 320, types: ["Dragon"], rarity: "Secret Rare", artist: "PLANETA Tsuji", text: "Once during your turn, you may draw 3 cards.", imageBase: "https://assets.tcgdex.net/en/swsh/swsh7/215", rawUsd: 92.5, rawEur: 85.0 },
  { id: "swsh7-94", localId: "94", name: "Umbreon V", hp: 200, types: ["Darkness"], rarity: "Rare", artist: "5ban", text: "", imageBase: null, rawUsd: null, rawEur: null },
  { id: "swsh7-1", localId: "1", name: "Lotad", hp: 70, types: ["Water"], rarity: "Common", artist: "x", text: "Rain Splash\nAqua Wave\nFlip a coin.", imageBase: "https://x/1", rawUsd: null, rawEur: null }
];
const prices = new Map<string, PptPrice>([
  ["swsh7-215", { tcgPlayerId: 246807, setName: "Evolving Skies", cardNumber: "215", name: "Rayquaza VMAX", raw: 92.5, graded: { psa8: 42, psa9: 180, psa10: 505 } }]
]);
const scenes = [
  { sceneId: "es-ray", title: "Rayquaza sky", cardIds: ["swsh7-215", "swsh7-94"] },
  { sceneId: "es-ray-narrative", title: "Rayquaza narrative arc", cardIds: ["swsh7-215", "swsh7-94"], kind: "narrative" as const },
];

describe("buildCatalog", () => {
  let dbPath: string;
  beforeAll(() => {
    dbPath = join(mkdtempSync(join(tmpdir(), "cat-")), "catalog.sqlite");
    buildCatalog({ sets, cardsBySet: new Map([["swsh7", cards]]), prices, scenes, asOf: "2026-07-04", dexByCard: new Map([["swsh7-215", [384]]]), pokemonNames: new Map([[384, "Rayquaza"]]) }, dbPath);
  });

  it("stores sets, cards, prices, scenes", () => {
    const db = new Database(dbPath, { readonly: true });
    expect(db.prepare("SELECT COUNT(*) n FROM card").get()).toEqual({ n: 3 });
    const ray = db.prepare("SELECT * FROM price_latest WHERE card_id = ?").get("swsh7-215") as any;
    expect(ray.raw_usd).toBe(92.5);
    expect(ray.raw_eur).toBe(85.0);
    expect(ray.psa10).toBe(505);
    expect(ray.psa8).toBe(42);   // every integer PSA grade ships, not just 3/7/9/10
    expect(ray.psa7).toBeNull();
    expect(ray.as_of).toBe("2026-07-04");
    expect(db.prepare("SELECT COUNT(*) n FROM connected_art WHERE scene_id='es-ray'").get()).toEqual({ n: 2 });
  });

  it("writes no price_latest row for a card with no raw and no graded price", () => {
    const db = new Database(dbPath, { readonly: true });
    const umbreon = db.prepare("SELECT * FROM price_latest WHERE card_id = ?").get("swsh7-94");
    expect(umbreon).toBeUndefined();
  });

  it("FTS5 finds cards by body text and by name", () => {
    const db = new Database(dbPath, { readonly: true });
    const byBody = db.prepare("SELECT card_id FROM card_text WHERE card_text MATCH ?").all('"draw 3 cards"') as any[];
    expect(byBody.map(r => r.card_id)).toContain("swsh7-215");
    const byName = db.prepare("SELECT card_id FROM card_text WHERE card_text MATCH ?").all("umbreon") as any[];
    expect(byName.map(r => r.card_id)).toContain("swsh7-94");
  });

  it("FTS5 finds a card by its attack NAME", () => {
    const db = new Database(dbPath, { readonly: true });
    const hits = db.prepare("SELECT card_id FROM card_text WHERE card_text MATCH ?").all('"Rain Splash"') as any[];
    expect(hits.map(r => r.card_id)).toContain("swsh7-1");
  });

  it("carries a kind column: defaults to combined, narrative scenes get kind='narrative'", () => {
    const db = new Database(dbPath, { readonly: true });
    const combined = db.prepare("SELECT DISTINCT kind FROM connected_art WHERE scene_id='es-ray'").get() as { kind: string } | undefined;
    expect(combined?.kind).toBe("combined");
    const narrative = db.prepare("SELECT DISTINCT kind FROM connected_art WHERE scene_id='es-ray-narrative'").get() as { kind: string } | undefined;
    expect(narrative?.kind).toBe("narrative");
  });

  it("skips scene rows whose cards are not in the catalog", () => {
    const p2 = join(mkdtempSync(join(tmpdir(), "cat2-")), "c.sqlite");
    buildCatalog({ sets, cardsBySet: new Map([["swsh7", cards]]), prices, scenes: [{ sceneId: "ghost", title: "Ghost", cardIds: ["nope-1", "swsh7-94"] }], asOf: "2026-07-04", dexByCard: new Map(), pokemonNames: new Map() }, p2);
    const db = new Database(p2, { readonly: true });
    expect(db.prepare("SELECT COUNT(*) n FROM connected_art WHERE scene_id='ghost'").get()).toEqual({ n: 1 });
  });

  it("writes card_dex rows, pokemon row (named), and set_info.rep_card_id", () => {
    const db = new Database(dbPath, { readonly: true });
    expect(db.prepare("SELECT dex_id FROM card_dex WHERE card_id='swsh7-215'").get()).toEqual({ dex_id: 384 });
    expect(db.prepare("SELECT name, rep_card_id FROM pokemon WHERE dex_id=384").get()).toEqual({ name: "Rayquaza", rep_card_id: "swsh7-215" });
    // swsh7-215 has the only raw_usd price in this set, so it's the set's representative too.
    expect(db.prepare("SELECT rep_card_id FROM set_info WHERE id='swsh7'").get()).toEqual({ rep_card_id: "swsh7-215" });
  });

  it("stores set_info.printed_total (printed base-count)", () => {
    const db = new Database(dbPath, { readonly: true });
    const row = db.prepare("SELECT printed_total FROM set_info WHERE id='swsh7'").get() as any;
    expect(row.printed_total).toBe(203);
  });

  it("falls back to #<dex> pokemon name when no name is supplied", () => {
    const p2 = join(mkdtempSync(join(tmpdir(), "cat3-")), "c.sqlite");
    buildCatalog({ sets, cardsBySet: new Map([["swsh7", cards]]), prices, scenes, asOf: "2026-07-04", dexByCard: new Map([["swsh7-94", [197]]]), pokemonNames: new Map() }, p2);
    const db = new Database(p2, { readonly: true });
    expect(db.prepare("SELECT name FROM pokemon WHERE dex_id=197").get()).toEqual({ name: "#197" });
  });

  it("stores image_url and creates an empty price_history table", () => {
    const dir = mkdtempSync(join(tmpdir(), "cat-"));
    const out = join(dir, "c.sqlite");
    const cardsBySet = new Map([["s1", [
      { id: "s1-1", localId: "1", name: "A", hp: null, types: [], rarity: null, artist: null,
        text: "", imageBase: null, imageUrl: "https://cdn/x.jpg", rawUsd: 5, rawEur: null },
    ]]]);
    buildCatalog({
      sets: [{ id: "s1", name: "S1", releaseDate: "2020-01-01", cardCountTotal: 1, printedTotal: null, serie: "E" }],
      cardsBySet, prices: new Map(), scenes: [], asOf: "2026-07-07",
      dexByCard: new Map(), pokemonNames: new Map(),
    }, out);
    const db = new Database(out, { readonly: true });
    const row = db.prepare("SELECT image_url FROM card WHERE id='s1-1'").get() as any;
    expect(row.image_url).toBe("https://cdn/x.jpg");
    const ph = db.prepare("SELECT COUNT(*) n FROM price_history").get() as any;
    expect(ph.n).toBe(0);
    db.close();
  });

  it("writes card_twin rows in both directions", () => {
    const p = join(mkdtempSync(join(tmpdir(), "twin-")), "c.sqlite");
    buildCatalog({ sets, cardsBySet: new Map([["swsh7", cards]]), prices, scenes: [], asOf: "2026-07-04", dexByCard: new Map(), pokemonNames: new Map(), twins: [["swsh7-1", "swsh7-215"]] }, p);
    const db = new Database(p, { readonly: true });
    const fwd = db.prepare("SELECT twin_id FROM card_twin WHERE card_id='swsh7-1'").all() as any[];
    const rev = db.prepare("SELECT twin_id FROM card_twin WHERE card_id='swsh7-215'").all() as any[];
    expect(fwd.map(r => r.twin_id)).toContain("swsh7-215");
    expect(rev.map(r => r.twin_id)).toContain("swsh7-1");
  });
});

describe("pickRepresentative", () => {
  const cards = new Map([
    ["a-1", { number: "1", imageBase: "img/a1" }],
    ["a-2", { number: "2", imageBase: "img/a2" }],
    ["a-3", { number: "3", imageBase: null }],
  ]);
  it("picks highest raw_usd", () => {
    const p = new Map([["a-1", { rawUsd: 5, rawEur: null }], ["a-2", { rawUsd: 9, rawEur: 1 }]]);
    expect(pickRepresentative(["a-1", "a-2"], p, cards)).toBe("a-2");
  });
  it("falls back to highest raw_eur when no usd", () => {
    const p = new Map([["a-1", { rawUsd: null, rawEur: 2 }], ["a-2", { rawUsd: null, rawEur: 7 }]]);
    expect(pickRepresentative(["a-1", "a-2"], p, cards)).toBe("a-2");
  });
  it("falls back to first card by number with an image when no prices", () => {
    expect(pickRepresentative(["a-3", "a-2"], new Map(), cards)).toBe("a-2");
  });
  it("prefers a priced (e.g. graded-only) card over a lower-numbered unpriced one", () => {
    const p = new Map([
      ["a-1", { rawUsd: null, rawEur: null, priced: false }],
      ["a-2", { rawUsd: null, rawEur: null, priced: true }],
    ]);
    expect(pickRepresentative(["a-1", "a-2"], p, cards)).toBe("a-2");
  });
  it("returns null when nothing qualifies", () => {
    expect(pickRepresentative(["a-3"], new Map(), cards)).toBeNull();
  });
});
