import { describe, it, expect } from "vitest";
import { attacksOf, effectText } from "../scripts/flatten-cards-db";

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
