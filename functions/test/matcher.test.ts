import { describe, it, expect } from "vitest";
import { matchPrices } from "../src/pipeline/matcher";
import type { TcgdexCard } from "../src/upstream/tcgdex";
import type { PptPrice } from "../src/upstream/ppt";

const card = (id: string, localId: string, name: string): TcgdexCard =>
  ({ id, localId, name, hp: null, types: [], rarity: null, artist: null, text: "", imageBase: null });
const price = (tcgPlayerId: number, cardNumber: string, name: string): PptPrice =>
  ({ tcgPlayerId, cardNumber, name, setName: "X", raw: 1, graded: {} });

describe("matchPrices", () => {
  it("matches plain and slash-formatted numbers", () => {
    const m = matchPrices([card("swsh7-215", "215", "Rayquaza VMAX")], [price(1, "215/203", "Rayquaza VMAX")]);
    expect(m.get("swsh7-215")?.tcgPlayerId).toBe(1);
  });

  it("strips leading zeros and matches promo prefixes case-insensitively", () => {
    const m = matchPrices(
      [card("swshp-SWSH123", "SWSH123", "Zacian V"), card("sv1-003", "003", "Sprigatito")],
      [price(2, "swsh123", "Zacian V"), price(3, "3/198", "Sprigatito")]
    );
    expect(m.get("swshp-SWSH123")?.tcgPlayerId).toBe(2);
    expect(m.get("sv1-003")?.tcgPlayerId).toBe(3);
  });

  it("leaves unmatched cards absent rather than guessing", () => {
    const m = matchPrices([card("swsh7-1", "1", "Pineco")], [price(9, "999/203", "Mewtwo")]);
    expect(m.has("swsh7-1")).toBe(false);
  });
});
