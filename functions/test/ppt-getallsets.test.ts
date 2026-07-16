import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget } from "../src/upstream/ppt";

function page(rows: any[]) {
  return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ data: rows }) } as any;
}

describe("getAllSets", () => {
  it("paginates with limit/offset until a short page and maps fields", async () => {
    const full = Array.from({ length: 100 }, (_, i) => ({ name: `S${i}`, tcgPlayerId: `s${i}`, series: "X", releaseDate: "2020-01-01T00:00:00.000Z" }));
    const seq = [page(full), page([{ name: "Last", tcgPlayerId: "last", series: "Y", releaseDate: null }])];
    let i = 0;
    const client = new PptClient("k", new CreditBudget(10), async () => seq[i++]);
    const sets = await client.getAllSets();
    expect(sets).toHaveLength(101);
    expect(sets[100]).toEqual({ name: "Last", slug: "last", series: "Y", releaseDate: null });
  });
});
