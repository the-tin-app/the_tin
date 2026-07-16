import { describe, it, expect } from "vitest";
import { computeFills } from "../src/pipeline/ppt-enrich";
import { PptCard } from "../src/upstream/ppt";

const ppt: PptCard[] = [
  { externalCatalogId: "s-1", cardNumber: "1", name: "A", imageUrl: "http://i/1.jpg", marketUsd: 4 },
  { externalCatalogId: "s-2", cardNumber: "2", name: "B", imageUrl: null, marketUsd: 9 },
  { externalCatalogId: "s-3", cardNumber: "3", name: "C", imageUrl: "http://i/3.jpg", marketUsd: 2 },
];

it("fills only missing fields for matched cards", () => {
  const fills = computeFills([
    { id: "s-1", localId: "1", name: "A", hasImage: false, hasPrice: false }, // both
    { id: "s-2", localId: "2", name: "B", hasImage: false, hasPrice: false }, // price only (ppt img null)
    { id: "s-3", localId: "3", name: "C", hasImage: true, hasPrice: true },    // nothing → omitted
    { id: "s-9", localId: "9", name: "Z", hasImage: false, hasPrice: false },  // unmatched → omitted
  ], ppt);
  expect(fills.get("s-1")).toEqual({ imageUrl: "http://i/1.jpg", rawUsd: 4 });
  expect(fills.get("s-2")).toEqual({ imageUrl: null, rawUsd: 9 });
  expect(fills.has("s-3")).toBe(false);
  expect(fills.has("s-9")).toBe(false);
});
