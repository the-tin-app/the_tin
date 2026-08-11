import { describe, it, expect } from "vitest";
import { attacksOf, detailOf, effectText } from "../scripts/flatten-cards-db";

describe("attacksOf", () => {
  it("keeps name, stringifies numeric damage, defaults cost", () => {
    expect(attacksOf({
      attacks: [
        { name: { en: "Razor Leaf" }, damage: 30, cost: ["Grass", "Colorless"] },
        { name: { en: "Solar Beam" }, damage: "60+" },
        { name: { fr: "Sans anglais" }, damage: 10 }, // no english name → dropped
      ],
    })).toEqual([
      { name: "Razor Leaf", damage: "30", cost: ["Grass", "Colorless"] },
      { name: "Solar Beam", damage: "60+", cost: [] },
    ]);
  });

  it("returns empty for a card with no attacks", () => {
    expect(attacksOf({})).toEqual([]);
  });

  // The REST API returns attack effects as plain strings; the repo stores them under `.en`.
  // pickAttacks gained `effect` and this path did not, so effects were silently absent.
  it("carries the english attack effect", () => {
    expect(attacksOf({
      attacks: [{ name: { en: "Thundershock" }, damage: 10, cost: ["Lightning"], effect: { en: "Flip a coin." } }],
    })).toEqual([{ name: "Thundershock", damage: "10", cost: ["Lightning"], effect: "Flip a coin." }]);
  });
});

// ⚠️ These fixtures are REPO-shaped, not REST-shaped, and that distinction is the whole point:
// `detail` shipped as a column of 23,548 NULLs in catalog v40 because pickDetail was only wired
// into the REST client, which the nightly never calls. Both are verbatim from cards-database.
describe("detailOf", () => {
  it("de-localizes a Pokémon's abilities and evolveFrom, and passes flat fields through", () => {
    expect(detailOf({
      category: "Pokemon",
      stage: "Stage1",
      evolveFrom: { en: "Bulbasaur" },
      abilities: [{ type: "Poke-BODY", name: { en: "Vine Pull" }, effect: { en: "Once during your turn…" } }],
      weaknesses: [{ type: "Fire", value: "×2" }],
      retreat: 2,
    })).toEqual({
      category: "Pokemon",
      stage: "Stage1",
      evolveFrom: "Bulbasaur",
      abilities: [{ name: "Vine Pull", type: "Poke-BODY", effect: "Once during your turn…" }],
      weaknesses: [{ type: "Fire", value: "×2" }],
      retreat: 2,
    });
  });

  it("de-localizes a Trainer's effect and keeps trainerType/regulationMark", () => {
    expect(detailOf({
      category: "Trainer",
      trainerType: "Supporter",
      regulationMark: "G",
      effect: { en: "Discard a Special Energy from each of your opponent's Pokémon." },
    })).toEqual({
      category: "Trainer",
      trainerType: "Supporter",
      regulationMark: "G",
      effect: "Discard a Special Energy from each of your opponent's Pokémon.",
    });
  });

  it("returns undefined when the card prints none of it", () => {
    expect(detailOf({ name: { en: "Some Card" } })).toBeUndefined();
  });

  it("drops a field that exists only in another language rather than emitting the wrong one", () => {
    expect(detailOf({ category: "Trainer", effect: { fr: "Défaussez…" } })).toEqual({ category: "Trainer" });
  });
});

describe("effectText", () => {
  it("includes attack/ability names alongside their effects", () => {
    const text = effectText({
      attacks: [
        { name: "Rain Splash", effect: "" },
        { name: "Aqua Wave", effect: "Flip a coin." },
      ],
    });
    expect(text).toContain("Rain Splash");
    expect(text).toContain("Aqua Wave");
    expect(text).toContain("Flip a coin");
  });

  it("returns empty string for a card with no abilities/attacks", () => {
    expect(effectText({})).toBe("");
  });
});
