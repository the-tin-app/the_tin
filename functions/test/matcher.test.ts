import { describe, it, expect } from "vitest";
import { matchPrices, matchPptToOurCards } from "../src/pipeline/matcher";
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

// Every case below is real data from PPT, 2026-08-18.
const ours = (id: string, number: string, name: string, tcgplayerId: number | null = null) =>
  ({ id, number, name, tcgplayerId });
const ppt = (cardNumber: string, name: string, tcgPlayerId: number | null = null) =>
  ({ cardNumber, name, tcgPlayerId });

describe("matchPptToOurCards", () => {
  it("gives a contested number to the product our card's tcgplayer_id names", () => {
    // PPT's "Nintendo Promos" holds 95 products for our 40-card set. `32/97` and `032` both
    // normalize to `32`, so a Gyarados Prerelease was writing into np-32 Articuno ex.
    const our = [ours("np-32", "32", "Articuno ex", 83655)];
    const gyarados = ppt("32/97", "Gyarados - 32/97 (Prerelease)", 239090);
    const articuno = ppt("032", "Articuno ex - 032 (EX Collector's Window Tins)", 83655);
    const m = matchPptToOurCards(our, [gyarados, articuno]);
    expect(m.get(articuno)?.id).toBe("np-32");
    expect(m.has(gyarados)).toBe(false);
  });

  it("splits a trainer kit's two decks, which PPT models as one set numbered 1-30 twice", () => {
    const our = [ours("tk-xy-p-9", "9", "Lightning Energy", 118805),
                 ours("tk-xy-su-9", "9", "Water Energy", 118833)];
    const m = matchPptToOurCards(our, [ppt("9/30", "Water Energy (9)", 118833),
                                       ppt("9/30", "Lightning Energy (9)", 118805)]);
    expect([...m.values()].map((c) => c.id).sort()).toEqual(["tk-xy-p-9", "tk-xy-su-9"]);
  });

  it("refuses a number match when both sides name different tcgplayer products", () => {
    // sv01 resolved to PPT's PROMO set: 0/258 ids agreed, and "Team Star Grunt" was priced as
    // "Lillie's Clefairy ex". Number alone must not survive that.
    const m = matchPptToOurCards([ours("sv01-195", "195", "Team Star Grunt", 1132570)],
                                 [ppt("195", "Lillie's Clefairy ex - 195", 654321)]);
    expect(m.size).toBe(0);
  });

  it("takes the unstamped base product over its Staff twin, with no ids on either side", () => {
    // smp carries a tcgplayer_id on 4 of its 248 cards, so the id test cannot referee there.
    // Our catalog models only the base card; PPT sells the $11.14 one and a $100 [Staff] stamp.
    const our = [ours("smp-98", "98", "Shinx")];
    const base = ppt("98/130", "Shinx - 98/130 (City Championships)");
    const staff = ppt("98/130", "Shinx - 98/130 (City Championships) [Staff]");
    const m = matchPptToOurCards(our, [staff, base]);
    expect(m.get(base)?.id).toBe("smp-98");
    expect(m.has(staff)).toBe(false);
  });

  it("writes nothing when every contender is stamped, or none uniquely unstamped", () => {
    // np-36 Tropical Tidal Wave: seven World Championships stampings, our id matches none.
    const m = matchPptToOurCards([ours("np-36", "36", "Tropical Tidal Wave", 90052)],
      ["[Staff]", "[Participation]", "[Finalist]"].map((tag) =>
        ppt("036", `Tropical Tidal Wave - 036 (2006 World Championships) ${tag}`, 224556)));
    expect(m.size).toBe(0);
    // smp-SM200: two parenthetical print runs, neither a stamp, neither ours by name.
    const two = matchPptToOurCards([ours("smp-SM200", "SM200", "Snubbull")], [
      ppt("SM200", "Snubbull - SM200 (In-Store Event Promo)"),
      ppt("SM200", "Snubbull - SM200 (Detective Pikachu Stamped)"),
    ]);
    expect(two.size).toBe(0);
  });

  it("lets an exact name match outrank a disagreeing id", () => {
    // `card.tcgplayer_id` is only the card's FIRST sku, so PPT reporting a different one for the
    // same card is normal: me02.5-155 N's Zekrom is ours 704446 against PPT's 675967.
    const zekrom = ppt("155", "N's Zekrom", 675967);
    const m = matchPptToOurCards([ours("me02.5-155", "155", "N's Zekrom", 704446)],
      [ppt("155", "N's Zekrom (Poke Ball)", 676973), zekrom]);
    expect(m.get(zekrom)?.id).toBe("me02.5-155");
  });

  it("breaks an id shared by two of our cards using PPT's name, not index order", () => {
    // np-16 Treecko and np-17 Torchic both carry 153317; it is Torchic's Target Promo sku.
    const target = ppt("017", "Torchic - 017 (Target Promo)", 153317);
    const m = matchPptToOurCards([ours("np-16", "16", "Treecko", 153317),
                                  ours("np-17", "17", "Torchic", 153317)], [target]);
    expect(m.get(target)?.id).toBe("np-17");
  });

  it("still matches on number alone when the number is uncontested", () => {
    const m = matchPptToOurCards([ours("swsh7-215", "215", "Umbreon VMAX", 247707)],
                                 [ppt("215/203", "Umbreon VMAX - 215/203")]);
    expect(m.size).toBe(1);
  });

  it("breaks a same-number tie by name when neither side carries an id", () => {
    const m = matchPptToOurCards([ours("x-1", "1", "Pikachu"), ours("x-1b", "1", "Raichu")],
                                 [ppt("1", "Raichu"), ppt("1", "Pikachu")]);
    expect([...m.values()].map((c) => c.id).sort()).toEqual(["x-1", "x-1b"]);
  });
});
