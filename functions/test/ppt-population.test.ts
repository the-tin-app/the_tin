import { describe, it, expect } from "vitest";
import { parsePopulation } from "../src/pipeline/ppt-population";

const sample = { data: {
  tcgPlayerId: "490294",
  populationByGrader: {
    PSA: { g8: 1500, g9: 8000, g10: 2500, auth: 50, qualifiers: 25, totalPopulation: 12075, gemRate: 20.70 },
    BGS: { g9: 1000, g9_5: 500, g10: 100, totalPopulation: 1830, gemRate: 7.10 },
  },
}};

describe("parsePopulation", () => {
  it("flattens populationByGrader into per-grade rows with denormalized grader stats", () => {
    const rows = parsePopulation(sample);
    const psa10 = rows.find(r => r.grader === "PSA" && r.grade === "g10");
    expect(psa10).toEqual({ tcgPlayerId: 490294, grader: "PSA", grade: "g10", count: 2500, gemRate: 20.70, totalPopulation: 12075 });
    // summary keys are not grade rows
    expect(rows.some(r => r.grade === "totalPopulation" || r.grade === "gemRate")).toBe(false);
    expect(rows.filter(r => r.grader === "BGS").length).toBe(3);
  });

  it("accepts a bulk `data` array and skips malformed graders", () => {
    const bulk = { data: [ sample.data, { tcgPlayerId: "1", populationByGrader: { PSA: null } } ] };
    const rows = parsePopulation(bulk);
    expect(rows.some(r => r.tcgPlayerId === 490294)).toBe(true);
    expect(rows.some(r => r.tcgPlayerId === 1)).toBe(false); // null grader → no rows
  });

  it("returns [] for empty/garbage", () => {
    expect(parsePopulation(null)).toEqual([]);
    expect(parsePopulation({ data: {} })).toEqual([]);
  });
});
