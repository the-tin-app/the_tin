import { describe, it, expect } from "vitest";
import { buildCardText } from "../src/upstream/tcgdex";

describe("buildCardText", () => {
  it("includes attack NAMES and effects", () => {
    const t = buildCardText({ attacks: [
      { name: "Rain Splash", effect: "" },
      { name: "Aqua Wave", effect: "Flip a coin. If heads, this attack does 20 more." },
    ] });
    expect(t).toContain("Rain Splash");
    expect(t).toContain("Aqua Wave");
    expect(t).toContain("Flip a coin");
  });

  it("includes ability names and effects", () => {
    const t = buildCardText({ abilities: [{ name: "Shadow Veil", effect: "Prevent all damage." }] });
    expect(t).toContain("Shadow Veil");
    expect(t).toContain("Prevent all damage");
  });

  it("drops blank names/effects and handles missing arrays", () => {
    expect(buildCardText({})).toBe("");
    expect(buildCardText({ attacks: [{ name: "", effect: "" }] })).toBe("");
  });
});
