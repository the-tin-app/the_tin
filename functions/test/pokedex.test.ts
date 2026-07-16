import { describe, it, expect } from "vitest";
import { normalizeSpeciesName } from "../scripts/build-pokedex";

describe("normalizeSpeciesName", () => {
  it("capitalizes a simple slug", () => expect(normalizeSpeciesName("pikachu")).toBe("Pikachu"));
  it("capitalizes each hyphen segment", () => expect(normalizeSpeciesName("ho-oh")).toBe("Ho-Oh"));
  it("handles multi-segment names", () => expect(normalizeSpeciesName("mr-mime")).toBe("Mr-Mime"));
});
