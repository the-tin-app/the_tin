import { describe, it, expect } from "vitest";
import { dexIdsOf } from "../scripts/flatten-cards-db";

describe("dexIdsOf", () => {
  it("returns the dexId array for a Pokémon card", () => expect(dexIdsOf({ dexId: [197] })).toEqual([197]));
  it("returns multiple ids for multi-Pokémon cards", () => expect(dexIdsOf({ dexId: [25, 644] })).toEqual([25, 644]));
  it("returns [] when dexId is absent (Trainer/Energy)", () => expect(dexIdsOf({})).toEqual([]));
  it("filters non-number entries", () => expect(dexIdsOf({ dexId: [1, null, "x"] })).toEqual([1]));
});
