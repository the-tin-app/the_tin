import { describe, it, expect } from "vitest";
import { TcgdexClient, pickTcgplayerMarket } from "../src/upstream/tcgdex";

const setListJson = [{ id: "swsh7", name: "Evolving Skies", cardCount: { total: 237 }, releaseDate: "2021-08-27", serie: { name: "Sword & Shield" } }];
const setJson = {
  cards: [{ id: "swsh7-215", localId: "215", name: "Rayquaza VMAX" }]
};
const cardJson = {
  id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: 320,
  types: ["Dragon"], rarity: "Secret Rare",
  illustrator: "PLANETA Tsuji",
  image: "https://assets.tcgdex.net/en/swsh/swsh7/215",
  abilities: [{ name: "Azure Pulse", effect: "Once during your turn, you may draw 3 cards." }],
  attacks: [{ name: "Max Burst", effect: "Discard energy...", damage: "320" }]
};

function stubFetch(routes: Record<string, unknown>): (url: string) => Promise<Response> {
  return async (url: string) => {
    for (const [suffix, body] of Object.entries(routes)) {
      if (url.endsWith(suffix)) return new Response(JSON.stringify(body), { status: 200 });
    }
    return new Response("not found", { status: 404 });
  };
}

describe("TcgdexClient", () => {
  it("lists sets with normalized fields", async () => {
    const c = new TcgdexClient(stubFetch({ "/sets": setListJson }));
    const sets = await c.listSets();
    expect(sets).toEqual([{ id: "swsh7", name: "Evolving Skies", releaseDate: "2021-08-27", cardCountTotal: 237, printedTotal: null, serie: "Sword & Shield" }]);
  });

  it("fetches set cards with full detail incl. searchable text", async () => {
    const c = new TcgdexClient(stubFetch({ "/sets/swsh7": setJson, "/cards/swsh7-215": cardJson }));
    const cards = await c.getSetCards("swsh7");
    expect(cards).toHaveLength(1);
    expect(cards[0]).toMatchObject({
      id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: 320,
      artist: "PLANETA Tsuji", imageBase: "https://assets.tcgdex.net/en/swsh/swsh7/215"
    });
    expect(cards[0].text).toContain("draw 3 cards");
    expect(cards[0].text).toContain("Discard energy");
  });

  it("throws a descriptive error on non-200", async () => {
    const c = new TcgdexClient(stubFetch({}));
    await expect(c.listSets()).rejects.toThrow(/TCGdex 404/);
  });
});

describe("pickTcgplayerMarket variant tie-break", () => {
  it("prefers normal, then holofoil, then reverse, then first present", () => {
    expect(pickTcgplayerMarket({ normal: { marketPrice: 1 }, reverse: { marketPrice: 2 } })).toBe(1);
    expect(pickTcgplayerMarket({ holofoil: { marketPrice: 3 }, reverse: { marketPrice: 2 } })).toBe(3);
    expect(pickTcgplayerMarket({ reverse: { marketPrice: 2 } })).toBe(2);
    expect(pickTcgplayerMarket({ "1stEdition": { marketPrice: 9 } })).toBe(9); // first present fallback
    expect(pickTcgplayerMarket(undefined)).toBeNull();
    expect(pickTcgplayerMarket({ normal: {} })).toBeNull(); // no marketPrice → null
  });
});

describe("getSetCards pricing extraction", () => {
  it("reads raw_usd from tcgplayer.<variant>.marketPrice and raw_eur from cardmarket.trend", async () => {
    const cardJson = {
      id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: 320, types: ["Dragon"],
      rarity: "Secret Rare", illustrator: "PLANETA Tsuji", image: "https://x/215",
      pricing: {
        tcgplayer: { unit: "USD", normal: { marketPrice: 92.5 }, reverse: { marketPrice: 40 } },
        cardmarket: { unit: "EUR", trend: 85.0 },
      },
    };
    const fetchFn = async (url: string) => {
      if (url.endsWith("/sets/swsh7")) return json({ cards: [{ id: "swsh7-215" }] });
      return json(cardJson);
    };
    const cards = await new TcgdexClient(fetchFn as any).getSetCards("swsh7");
    expect(cards[0].rawUsd).toBe(92.5);
    expect(cards[0].rawEur).toBe(85.0);
  });
});

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
}
