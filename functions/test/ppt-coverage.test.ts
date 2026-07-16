import { describe, it, expect } from "vitest";
import { computeCoverage, OurCard } from "../src/pipeline/ppt-coverage";
import { PptCard } from "../src/upstream/ppt";

const ppt: PptCard[] = [
  { externalCatalogId: "mep-1", cardNumber: "1", name: "Pikachu", imageUrl: "http://img/1.jpg", marketUsd: 3.0 },
  { externalCatalogId: "mep-2", cardNumber: "2", name: "Charizard", imageUrl: "http://img/2.jpg", marketUsd: null },
];

describe("computeCoverage", () => {
  it("counts image- and price-fillable gaps against matched PPT cards", () => {
    const ours: OurCard[] = [
      { id: "mep-1", localId: "1", name: "Pikachu", hasImage: false, hasPrice: false },   // img+price fillable
      { id: "mep-2", localId: "2", name: "Charizard", hasImage: false, hasPrice: false },  // img fillable, price not (null)
      { id: "mep-9", localId: "9", name: "Ghost", hasImage: false, hasPrice: false },      // unmatched
    ];
    expect(computeCoverage(ours, ppt)).toEqual({ matched: 2, imageFillable: 2, priceFillable: 1 });
  });

  it("does not count cards that already have an image or price", () => {
    const ours: OurCard[] = [{ id: "mep-1", localId: "1", name: "Pikachu", hasImage: true, hasPrice: true }];
    expect(computeCoverage(ours, ppt)).toEqual({ matched: 1, imageFillable: 0, priceFillable: 0 });
  });

  it("disambiguates same-number PPT candidates by name match", () => {
    const dupNumberPpt: PptCard[] = [
      // Wrong-name candidate listed first, with no fillable data: if the code
      // naively picked the first same-number candidate instead of matching by
      // name, this test would assert imageFillable:0, priceFillable:0 and fail.
      { externalCatalogId: "mep-1a", cardNumber: "1", name: "Raichu", imageUrl: null, marketUsd: null },
      { externalCatalogId: "mep-1b", cardNumber: "1", name: "Pikachu", imageUrl: "http://img/1b.jpg", marketUsd: 5.0 },
    ];
    const ours: OurCard[] = [{ id: "mep-1", localId: "1", name: "Pikachu", hasImage: false, hasPrice: false }];
    expect(computeCoverage(ours, dupNumberPpt)).toEqual({ matched: 1, imageFillable: 1, priceFillable: 1 });
  });

  it("treats a card as unmatched when same-number PPT candidates all have different names", () => {
    const dupNumberPpt: PptCard[] = [
      { externalCatalogId: "mep-1a", cardNumber: "1", name: "Raichu", imageUrl: "http://img/1a.jpg", marketUsd: 3.0 },
      { externalCatalogId: "mep-1b", cardNumber: "1", name: "Sandshrew", imageUrl: "http://img/1b.jpg", marketUsd: 5.0 },
    ];
    const ours: OurCard[] = [{ id: "mep-1", localId: "1", name: "Pikachu", hasImage: false, hasPrice: false }];
    expect(computeCoverage(ours, dupNumberPpt)).toEqual({ matched: 0, imageFillable: 0, priceFillable: 0 });
  });
});
