import { describe, it, expect } from "vitest";
import { resolvePptSetName, PptSetInfo, PPT_SET_ALIASES } from "../src/pipeline/ppt-setmap";

const PPT: PptSetInfo[] = [
  { name: "SV: Prismatic Evolutions", slug: "sv-prismatic-evolutions", series: "Scarlet & Violet", releaseDate: "2025-01-17T00:00:00.000Z" },
  { name: "SV02: Paldea Evolved", slug: "sv02-paldea-evolved", series: "Scarlet & Violet", releaseDate: "2023-06-09T00:00:00.000Z" },
  { name: "McDonald's 2018", slug: "mcdonalds-2018", series: "Other", releaseDate: "2018-10-19T00:00:00.000Z" },
];

describe("resolvePptSetName", () => {
  it("matches when PPT name contains our name and years agree", () => {
    const m = resolvePptSetName({ id: "sv08.5", name: "Prismatic Evolutions", releaseDate: "2025-01-17" }, PPT);
    expect(m?.slug).toBe("sv-prismatic-evolutions");
  });

  it("does not match when the release years differ", () => {
    const m = resolvePptSetName({ id: "x", name: "Paldea Evolved", releaseDate: "2099-06-09" }, PPT);
    expect(m).toBeNull();
  });

  it("returns null when nothing resembles our set", () => {
    expect(resolvePptSetName({ id: "mep", name: "MEP Black Star Promos", releaseDate: "2025-09-26" }, PPT)).toBeNull();
  });

  it("matches on exact release date even when the name is unrelated (single same-day set)", () => {
    // Our name "Paldea Evolved 150-card deck" doesn't name-match, but the date is unique in PPT.
    const m = resolvePptSetName({ id: "sv02d", name: "Paldea Evolved Build & Battle", releaseDate: "2023-06-09" }, PPT);
    expect(m?.slug).toBe("sv02-paldea-evolved");
  });

  it("disambiguates multiple same-day PPT sets by name relation", () => {
    const ppt: PptSetInfo[] = [
      { name: "SV: Surging Sparks", slug: "sv08-surging-sparks", series: "SV", releaseDate: "2024-11-08" },
      { name: "SV: Surging Sparks Galarian Gallery", slug: "sv08-gg", series: "SV", releaseDate: "2024-11-08" },
    ];
    const m = resolvePptSetName({ id: "sv08gg", name: "Surging Sparks Galarian Gallery", releaseDate: "2024-11-08" }, ppt);
    expect(m?.slug).toBe("sv08-gg");
  });

  it("returns null when same-day PPT sets are ambiguous and none is name-related", () => {
    const ppt: PptSetInfo[] = [
      { name: "Alpha", slug: "a", series: "X", releaseDate: "2020-05-01" },
      { name: "Beta", slug: "b", series: "X", releaseDate: "2020-05-01" },
    ];
    expect(resolvePptSetName({ id: "z", name: "Gamma", releaseDate: "2020-05-01" }, ppt)).toBeNull();
  });

  it("a curated alias resolves to the exact PPT set even when name and date don't help", () => {
    // mep shares its release date (2025-09-26) with 3 PPT sets and its name relates to none.
    const ppt: PptSetInfo[] = [
      { name: "ME: Mega Evolution Promo", slug: "me-promo", series: "ME", releaseDate: "2025-09-26" },
      { name: "ME01: Mega Evolution", slug: "me01", series: "ME", releaseDate: "2025-09-26" },
      { name: "MEE: Mega Evolution Energies", slug: "mee", series: "ME", releaseDate: "2025-09-26" },
    ];
    expect(PPT_SET_ALIASES["mep"]).toBe("ME: Mega Evolution Promo");
    const m = resolvePptSetName({ id: "mep", name: "MEP Black Star Promos", releaseDate: "2025-09-26" }, ppt);
    expect(m?.slug).toBe("me-promo");
  });

  it("an aliased set whose PPT target is absent returns null (no heuristic fallthrough)", () => {
    // Even though a name-relatable set shares the date, the alias governs and its target is missing.
    const ppt: PptSetInfo[] = [
      { name: "MEP Black Star Promos deck", slug: "decoy", series: "ME", releaseDate: "2025-09-26" },
    ];
    expect(resolvePptSetName({ id: "mep", name: "MEP Black Star Promos", releaseDate: "2025-09-26" }, ppt)).toBeNull();
  });
});
