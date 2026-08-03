import { describe, it, expect } from "vitest";
import {
  numberKeys, denominatorFits, parseAttack, cleanName, mapGroupsToSets, synthesizeMissingCards,
  type TcgcsvProduct,
} from "../src/pipeline/tcgcsv-cards";

const ext = (o: Record<string, string>) => Object.entries(o).map(([name, value]) => ({ name, value }));
const product = (productId: number, name: string, e: Record<string, string>): TcgcsvProduct =>
  ({ productId, name, extendedData: ext(e) });

/** The real MEP 046 record, verbatim from tcgcsv — the card that started this. */
const CHIKORITA = product(699870, "Chikorita - 046", {
  Number: "046", Rarity: "Promo", "Card Type": "Grass", HP: "70", Stage: "Basic",
  "Attack 1": "[GC] Razor Leaf (30)", Weakness: "Rx2", RetreatCost: "1",
});

describe("numberKeys", () => {
  it("matches the same card written the two ways TCGplayer and the catalog write it", () => {
    // Observed false positives before this existed: both reported as missing cards.
    expect([...numberKeys("SVP193")]).toContain("193");   // catalog stores "193"
    expect([...numberKeys("226/S-P")]).toContain("226");  // catalog stores "SWSH226"
    expect([...numberKeys("226/S-P")]).toContain("SWSH226".slice(4));
    expect([...numberKeys("069")]).toContain("69");
    expect([...numberKeys("SVP 200")]).toContain("200");
  });
  it("is empty for a missing number so the caller skips rather than inventing an id", () => {
    expect(numberKeys(undefined).size).toBe(0);
    expect(numberKeys("").size).toBe(0);
  });
});

describe("denominatorFits", () => {
  it("rejects a reprint numbered by its ORIGINAL set", () => {
    // "Dark Gyarados 8/82" sits in the Celebrations Classic Collection group but is Neo
    // Genesis' numbering; cel25cc was already complete at 25/25.
    expect(denominatorFits("8/82", 25, 25)).toBe(false);
  });
  it("accepts a printed total that differs from `total` because of secret rares", () => {
    // Aquapolis prints x/147 while total is 185 — Memory Berry 128/147 is a genuine hole.
    expect(denominatorFits("128/147", 185, 147)).toBe(true);
  });
  it("accepts numbers that make no numeric claim", () => {
    expect(denominatorFits("046", 60, null)).toBe(true);
    expect(denominatorFits("226/S-P", 307, null)).toBe(true);
  });
});

describe("parseAttack", () => {
  it("pulls cost, name and damage out of the tcgcsv encoding", () => {
    expect(parseAttack("[GC] Razor Leaf (30)")).toEqual({
      name: "Razor Leaf", damage: "30", cost: ["Grass", "Colorless"], effect: "",
    });
  });
  it("keeps the effect text after the <br> and strips markup", () => {
    const a = parseAttack("[PP] Shooting Moons (120+)<br> You may discard up to 4 Energy cards.");
    expect(a?.name).toBe("Shooting Moons");
    expect(a?.damage).toBe("120+");
    expect(a?.effect).toBe("You may discard up to 4 Energy cards.");
  });
  it("handles an attack with no damage and no cost", () => {
    expect(parseAttack("Growl")).toMatchObject({ name: "Growl", damage: null, cost: [] });
  });
  it("reads digits in the cost bracket as colorless, and keeps them out of the name", () => {
    // Regression: "[3]" failed the letters-only bracket, so the name came out "[3] Victory
    // Symbol" — and the name is the field FTS indexes, so the card was unfindable by attack.
    expect(parseAttack("[3] Victory Symbol\r\n<br>If you use this attack…")).toMatchObject({
      name: "Victory Symbol", damage: null, cost: ["Colorless", "Colorless", "Colorless"],
    });
    expect(parseAttack("[1P] Hypnostrike (60)")).toMatchObject({
      name: "Hypnostrike", damage: "60", cost: ["Colorless", "Psychic"],
    });
  });
});

describe("cleanName", () => {
  it("strips the number suffix but keeps the print treatment", () => {
    expect(cleanName("Chikorita - 046", "046")).toBe("Chikorita");
    expect(cleanName("Mega Clefable ex - 072", "072")).toBe("Mega Clefable ex");
    expect(cleanName("Jirachi V - 299", "SWSH299")).toBe("Jirachi V");
    expect(cleanName("Slowbro - 083 (Pitch Black Stamped)", "083")).toBe("Slowbro (Pitch Black Stamped)");
    expect(cleanName("Memory Berry", "128")).toBe("Memory Berry");
  });
});

describe("mapGroupsToSets", () => {
  const known = new Map<number, string>(Array.from({ length: 20 }, (_, i) => [100 + i, "mep"]));

  it("maps a group by the products already resolved in it", () => {
    const groups = [{ groupId: 1, products: [...known.keys()].map((id) => product(id, "x", {})) }];
    expect(mapGroupsToSets(groups, known).get(1)).toBe("mep");
  });

  it("refuses a group with too little evidence, however unanimous", () => {
    // "Jumbo Cards" matched exactly ONE product and would have claimed `svp` at 100%
    // confidence, inventing 173 cards out of an unrelated group.
    const groups = [{ groupId: 9, products: [product(100, "x", {}), ...Array.from({ length: 341 }, (_, i) => product(90000 + i, "y", {}))] }];
    expect(mapGroupsToSets(groups, known).has(9)).toBe(false);
  });

  it("refuses a group that straddles two sets", () => {
    // Trainer kits ship two 30-card decks in one TCGplayer group, ~50/50.
    const split = new Map<number, string>();
    for (let i = 0; i < 15; i++) split.set(200 + i, "tk-sm-l");
    for (let i = 0; i < 15; i++) split.set(300 + i, "tk-sm-r");
    const groups = [{ groupId: 7, products: [...split.keys()].map((id) => product(id, "x", {})) }];
    expect(mapGroupsToSets(groups, split).size).toBe(0);
  });

  it("gives a set to the single best-evidenced group when two claim it", () => {
    const groups = [
      { groupId: 1, products: [...known.keys()].slice(0, 12).map((id) => product(id, "x", {})) },
      { groupId: 2, products: [...known.keys()].map((id) => product(id, "x", {})) },
    ];
    const m = mapGroupsToSets(groups, known);
    expect(m.get(2)).toBe("mep");
    expect(m.has(1)).toBe(false);
  });
});

describe("synthesizeMissingCards", () => {
  const known = new Map<number, string>(Array.from({ length: 20 }, (_, i) => [100 + i, "mep"]));
  const base = {
    setByTcgplayerId: known,
    numbersBySet: new Map([["mep", new Set(["69", "069"])]]),
    setTotals: new Map([["mep", { total: 60, printedTotal: null }]]),
  };
  const withProducts = (extra: TcgcsvProduct[]) => ({
    ...base,
    groups: [{ groupId: 1, products: [...[...known.keys()].map((id) => product(id, "x", {})), ...extra] }],
  });

  it("creates the missing card, fully populated", () => {
    const { cards, addedBySet } = synthesizeMissingCards({
      ...withProducts([CHIKORITA]),
      dexByName: new Map([["chikorita", 152]]),
    });
    expect(cards).toHaveLength(1);
    expect(cards[0]).toMatchObject({
      id: "mep-046", setId: "mep", localId: "046", name: "Chikorita",
      hp: 70, types: ["Grass"], rarity: "Promo", tcgplayerIds: [699870], dexId: [152],
    });
    expect(cards[0].attacks).toEqual([{ name: "Razor Leaf", damage: "30", cost: ["Grass", "Colorless"] }]);
    expect(addedBySet.get("mep")).toBe(1);
  });

  it("never duplicates a card the catalog already has", () => {
    const existing = product(686342, "Chikorita (Cosmos Holo)", {
      Number: "069", Rarity: "Promo", "Card Type": "Grass", HP: "70", "Attack 1": "[G] Razor Leaf (20)",
    });
    expect(synthesizeMissingCards(withProducts([existing])).cards).toHaveLength(0);
  });

  it("never emits two cards for one number", () => {
    const staff = product(707701, "Chikorita - 046 [Staff]", { Number: "046", "Card Type": "Grass", HP: "70" });
    expect(synthesizeMissingCards(withProducts([CHIKORITA, staff])).cards).toHaveLength(1);
  });

  it("skips sealed products, which carry no card fields", () => {
    const sealed = product(704143, "30th Celebration Elite Trainer Box", { Number: "046" });
    expect(synthesizeMissingCards(withProducts([sealed])).cards).toHaveLength(0);
  });

  it("skips a reprint numbered by another set instead of filing it here", () => {
    const reprint = product(555000, "Dark Gyarados", { Number: "8/82", "Card Type": "Water", HP: "90" });
    const r = synthesizeMissingCards(withProducts([reprint]));
    expect(r.cards).toHaveLength(0);
    expect(r.skippedForeignDenominator).toBe(1);
  });

  it("adds nothing from a group it could not map", () => {
    const r = synthesizeMissingCards({ ...base, groups: [{ groupId: 42, products: [CHIKORITA] }] });
    expect(r.cards).toHaveLength(0);
  });
});
