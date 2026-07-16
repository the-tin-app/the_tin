import { describe, it, expect } from "vitest";
import { effectText } from "../scripts/flatten-cards-db";

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
