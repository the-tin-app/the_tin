import { describe, it, expect, beforeAll } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildCatalog } from "../src/pipeline/catalog";
import type { TcgdexCard, TcgdexSet } from "../src/upstream/tcgdex";

const sets: TcgdexSet[] = [{ id: "swsh3", name: "Darkness Ablaze", releaseDate: "2020-08-14", cardCountTotal: 201, printedTotal: 189, serie: "Sword & Shield" }];

const cards: TcgdexCard[] = [
  {
    id: "swsh3-136", localId: "136", name: "Furret", hp: 90, types: ["Colorless"],
    rarity: "Uncommon", artist: "tetsuya koizumi", text: "", imageBase: "https://x/136",
    rawUsd: null, rawEur: null,
    attacks: [{ name: "Tail Smash", damage: "90", cost: ["Colorless"], effect: "Flip a coin." }],
    detail: { category: "Pokemon", stage: "Stage1", evolveFrom: "Sentret", retreat: 1, weaknesses: [{ type: "Fighting", value: "×2" }] },
  },
  // No detail at all — an Energy card, or any card the upstream had nothing extra for.
  { id: "swsh3-1", localId: "1", name: "Weedle", hp: 60, types: ["Grass"], rarity: "Common", artist: "x", text: "", imageBase: null, rawUsd: null, rawEur: null },
];

describe("card.detail column", () => {
  let db: InstanceType<typeof Database>;
  beforeAll(() => {
    const path = join(mkdtempSync(join(tmpdir(), "cat-detail-")), "catalog.sqlite");
    buildCatalog({ sets, cardsBySet: new Map([["swsh3", cards]]), prices: new Map(), scenes: [], asOf: "2026-08-10", dexByCard: new Map(), pokemonNames: new Map() }, path);
    db = new Database(path, { readonly: true });
  });

  it("round-trips the whole blob", () => {
    const row = db.prepare("SELECT detail FROM card WHERE id = ?").get("swsh3-136") as { detail: string };
    expect(JSON.parse(row.detail)).toEqual(cards[0].detail);
  });

  it("stores NULL rather than '{}' when there is nothing to say", () => {
    const row = db.prepare("SELECT detail FROM card WHERE id = ?").get("swsh3-1") as { detail: string | null };
    expect(row.detail).toBeNull();
  });

  it("carries attack effect text, which used to be dropped into the FTS blob and lost", () => {
    const row = db.prepare("SELECT attacks FROM card WHERE id = ?").get("swsh3-136") as { attacks: string };
    expect(JSON.parse(row.attacks)[0].effect).toBe("Flip a coin.");
  });

  it("is on `card`, so it survives into EVERY tier including casual", () => {
    // The sheet's whole purpose is working offline; tier is orthogonal to that. `splitTiers` only
    // drops price_history_cond/graded_history and empties price_history, so a column on `card`
    // needs no change there — this asserts nobody later moves it to a droppable table.
    const cols = (db.prepare("PRAGMA table_info(card)").all() as { name: string }[]).map((c) => c.name);
    expect(cols).toContain("detail");
  });
});
