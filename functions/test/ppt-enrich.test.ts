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

// ---------- #185's collision, on the gap-fill path (see ppt-enrich.ts) ----------

it("does not copy one PPT product onto every card whose number normalizes alike", () => {
  // `normalizeNumber` drops the denominator, so `32/97` and our `032` both key on `32`. The old
  // code looked PPT up per OUR card and took the sole same-numbered product without checking the
  // name, so this single Gyarados filled Articuno ex too — the exact np-32 corruption #185 found,
  // arriving as a wrong image and a wrong raw price instead of wrong history.
  const fills = computeFills(
    [
      { id: "np-32", localId: "32", name: "Articuno ex", hasImage: false, hasPrice: false },
      { id: "np-032", localId: "032", name: "Gyarados", hasImage: false, hasPrice: false },
    ],
    [{ externalCatalogId: "np-g", cardNumber: "32/97", name: "Gyarados", imageUrl: "http://i/g.jpg", marketUsd: 262.5 }],
  );
  expect(fills.get("np-032")).toEqual({ imageUrl: "http://i/g.jpg", rawUsd: 262.5 });
  expect(fills.has("np-32")).toBe(false);
});

it("refuses a bare-number match whose tcgPlayerId disagrees", () => {
  const fills = computeFills(
    [{ id: "c1", localId: "5", name: "Foo", tcgplayerId: 111, hasImage: false, hasPrice: false }],
    [{ externalCatalogId: "x", tcgPlayerId: 999, cardNumber: "5", name: "Something Else", imageUrl: "http://i/x.jpg", marketUsd: 7 }],
  );
  expect(fills.has("c1")).toBe(false);
});

it("matches on tcgPlayerId even though PPT's name never equals ours", () => {
  // The whole point of plumbing the id: these are promo sets, where PPT names carry
  // " - <Number> (<Print run>)" and no name comparison will ever succeed.
  const fills = computeFills(
    [{ id: "c1", localId: "SM72", name: "Alolan Raichu", tcgplayerId: 12345, hasImage: false, hasPrice: false }],
    [{ externalCatalogId: "x", tcgPlayerId: 12345, cardNumber: "SM72", name: "Alolan Raichu - SM72 (Prerelease)", imageUrl: "http://i/r.jpg", marketUsd: 10 }],
  );
  expect(fills.get("c1")).toEqual({ imageUrl: "http://i/r.jpg", rawUsd: 10 });
});

it("recovers a stamped-variant group by filling from the unstamped base card", () => {
  // Old behaviour: two candidates → name check → neither equals "Alolan Raichu" → no fill at all.
  const fills = computeFills(
    [{ id: "c1", localId: "SM72", name: "Alolan Raichu", hasImage: false, hasPrice: false }],
    [
      { externalCatalogId: "a", cardNumber: "SM72", name: "Alolan Raichu - SM72 (Prerelease) [Staff]", imageUrl: "http://i/staff.jpg", marketUsd: 99 },
      { externalCatalogId: "b", cardNumber: "SM72", name: "Alolan Raichu - SM72 (Prerelease)", imageUrl: "http://i/base.jpg", marketUsd: 10 },
    ],
  );
  expect(fills.get("c1")).toEqual({ imageUrl: "http://i/base.jpg", rawUsd: 10 });
});
