import { describe, it, expect } from "vitest";
import { dexIdsOf, collectThirdParty, pptPrintingName } from "../scripts/flatten-cards-db";

describe("dexIdsOf", () => {
  it("returns the dexId array for a Pokémon card", () => expect(dexIdsOf({ dexId: [197] })).toEqual([197]));
  it("returns multiple ids for multi-Pokémon cards", () => expect(dexIdsOf({ dexId: [25, 644] })).toEqual([25, 644]));
  it("returns [] when dexId is absent (Trainer/Energy)", () => expect(dexIdsOf({})).toEqual([]));
  it("filters non-number entries", () => expect(dexIdsOf({ dexId: [1, null, "x"] })).toEqual([1]));
});

describe("pptPrintingName", () => {
  it("maps known tcgdex variant types to PPT printing keys", () => {
    expect(pptPrintingName("normal")).toBe("Normal");
    expect(pptPrintingName("holo")).toBe("Holofoil");
    expect(pptPrintingName("reverse")).toBe("Reverse Holofoil");
    expect(pptPrintingName("firstEdition")).toBe("1st Edition");
  });
  it("passes unknown types through verbatim", () => {
    expect(pptPrintingName("lenticular")).toBe("lenticular");
    expect(pptPrintingName("card")).toBe("card");
  });
});

describe("collectThirdParty", () => {
  it("keeps labeled tcgplayer SKUs in variant-priority order", () => {
    const card = {
      name: { en: "Pikachu" },
      variants: [
        { type: "reverse", thirdParty: { tcgplayer: 300 } },
        { type: "normal", thirdParty: { tcgplayer: 100 } },
        { type: "holo", thirdParty: { tcgplayer: 200 } },
      ],
      thirdParty: { tcgplayer: 999 },
    };
    const { tcgplayerByType } = collectThirdParty(card);
    expect(tcgplayerByType).toEqual([["normal", 100], ["holo", 200], ["reverse", 300], ["card", 999]]);
  });
});
