import { describe, it, expect } from "vitest";
import { pickDetail, pickAttacks } from "../src/upstream/tcgdex";

/**
 * Payload shapes copied VERBATIM from the live API on 2026-08-10 (`swsh3-136`, `base1-4`,
 * `swsh12-160`). The point of this file is that the field names are right — they were guessed
 * wrong once already (`text` vs `effect`) and a guess here fails silently: the column fills with
 * `{}` and the fact sheet renders blank rows forever.
 */
const FURRET = {
  category: "Pokemon", stage: "Stage1", evolveFrom: "Sentret", regulationMark: "D", retreat: 1,
  weaknesses: [{ type: "Fighting", value: "×2" }],
  attacks: [
    { cost: ["Colorless"], name: "Feelin' Fine", effect: "Draw 3 cards." },
    { cost: ["Colorless"], name: "Tail Smash", effect: "Flip a coin. If tails, this attack does nothing.", damage: 90 },
  ],
};

const CHARIZARD = {
  category: "Pokemon", stage: "Stage2", evolveFrom: "Charmeleon", retreat: 3,
  abilities: [{ type: "Pokemon Power", name: "Energy Burn", effect: "As often as you like…" }],
  weaknesses: [{ type: "Water", value: "×2" }],
  resistances: [{ type: "Fighting", value: "-30" }],
};

const TOOL = {
  category: "Trainer", regulationMark: "F", trainerType: "Tool",
  effect: "Whenever your opponent plays a Supporter card from their hand…",
};

describe("pickDetail", () => {
  it("keeps the structure buildCardText throws away", () => {
    expect(pickDetail(FURRET)).toEqual({
      category: "Pokemon", stage: "Stage1", evolveFrom: "Sentret", regulationMark: "D",
      retreat: 1, weaknesses: [{ type: "Fighting", value: "×2" }],
    });
  });

  it("reads abilities and resistances", () => {
    const d = pickDetail(CHARIZARD)!;
    expect(d.abilities).toEqual([{ type: "Pokemon Power", name: "Energy Burn", effect: "As often as you like…" }]);
    expect(d.resistances).toEqual([{ type: "Fighting", value: "-30" }]);
  });

  it("reads a Trainer's top-level effect, which is where its rules text lives", () => {
    const d = pickDetail(TOOL)!;
    expect(d.trainerType).toBe("Tool");
    expect(d.effect).toContain("Supporter card");
    expect(d.abilities).toBeUndefined();
  });

  it("OMITS absent keys rather than emitting null", () => {
    // Load-bearing: JSON.stringify drops undefined, and every Swift field is a real Optional so a
    // missing key decodes as nil. An explicit null would decode fine too, but every one costs
    // bytes on 23k rows and says "we looked and there is nothing" when we simply did not look.
    const d = pickDetail(FURRET)!;
    expect("abilities" in d).toBe(false);
    expect("resistances" in d).toBe(false);
    expect(JSON.stringify(d)).not.toContain("null");
  });

  it("returns undefined for a card with nothing to say, so the column stays NULL", () => {
    expect(pickDetail({})).toBeUndefined();
    expect(pickDetail({ abilities: [] })).toBeUndefined();
  });

  it("survives junk without inventing fields", () => {
    expect(pickDetail({ retreat: "1", weaknesses: "Fighting", abilities: [{ effect: "no name" }] })).toBeUndefined();
  });
});

describe("pickAttacks with effect", () => {
  it("stringifies NUMERIC damage — the API sends 90, not '90'", () => {
    const attacks = pickAttacks(FURRET);
    expect(attacks[1].damage).toBe("90");
    expect(attacks[1].effect).toBe("Flip a coin. If tails, this attack does nothing.");
  });

  it("omits effect when the attack has none, keeping old blobs byte-comparable", () => {
    const [a] = pickAttacks({ attacks: [{ name: "Tackle", damage: "10", cost: ["Colorless"] }] });
    expect("effect" in a).toBe(false);
  });
});
