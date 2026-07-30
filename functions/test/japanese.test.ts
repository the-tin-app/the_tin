import { describe, it, expect } from "vitest";
import { parseEcbDaily, eurToUsd, ECB_DAILY_URL, fetchEurUsd } from "../src/upstream/fx";
import { jaSetId, jaCardId, collidingIds, toFlatSet, toFlatCard, jaRawUsd, isJapanese } from "../src/pipeline/japanese";
import type { TcgdexCard, TcgdexSet } from "../src/upstream/tcgdex";

// The real feed, byte-for-byte in shape, trimmed to three currencies (fetched 2026-07-29).
const ECB_XML = `<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<gesmes:subject>Reference rates</gesmes:subject>
<Cube><Cube time='2026-07-29'>
<Cube currency='USD' rate='1.1380'/>
<Cube currency='JPY' rate='166.53'/>
<Cube currency='GBP' rate='0.84520'/>
</Cube></Cube></gesmes:Envelope>`;

describe("ECB reference rate", () => {
  it("reads the rate and the publication date", () => {
    expect(parseEcbDaily(ECB_XML)).toEqual({ rate: 1.138, date: "2026-07-29" });
  });

  /// The one thing that must never be silently defaulted: a wrong FX rate misprices an entire
  /// catalogue and nothing downstream would notice, where a missing one stops the build.
  it("throws rather than guessing when the rate is absent", () => {
    expect(() => parseEcbDaily(ECB_XML.replace(/currency='USD'[^/]*\/>/, ""))).toThrow(/USD rate/);
    expect(() => parseEcbDaily("<xml/>")).toThrow();
  });

  it("throws on a date it cannot read", () => {
    expect(() => parseEcbDaily(ECB_XML.replace("time='2026-07-29'", ""))).toThrow(/time/);
  });

  /// A zero rate would zero every Japanese price rather than fail — the exact failure mode the
  /// "never fall back" rule exists to prevent, arriving through the front door.
  it("refuses an implausible rate", () => {
    expect(() => parseEcbDaily(ECB_XML.replace("1.1380", "0"))).toThrow(/implausible/);
    expect(() => parseEcbDaily(ECB_XML.replace("1.1380", "-1"))).toThrow(/implausible/);
  });

  /// ECB publishes on business days only, so a Sunday run legitimately gets Friday's file. Stale
  /// is SUCCESS — treating it as an error would halt the nightly every bank holiday.
  it("accepts a stale rate, because a bank holiday is not a failure", async () => {
    const stale = ECB_XML.replace("2026-07-29", "2026-07-24");
    const fx = await fetchEurUsd(async (url) => {
      expect(url).toBe(ECB_DAILY_URL);
      return new Response(stale, { status: 200 });
    });
    expect(fx.date).toBe("2026-07-24");
    expect(fx.rate).toBe(1.138);
  });

  it("converts to cents, and leaves an unpriced card unpriced", () => {
    const fx = { rate: 1.138, date: "2026-07-29" };
    expect(eurToUsd(10, fx)).toBe(11.38);
    expect(eurToUsd(0.06, fx)).toBe(0.07);
    expect(eurToUsd(null, fx)).toBeNull();
    expect(eurToUsd(undefined, fx)).toBeNull();
  });
});

describe("Japanese namespacing", () => {
  /// THE test on this feature. Verified against the live API 2026-07-29: EN `neo1` is Neo Genesis
  /// (111 cards), JA `neo1` is 金、銀、新世界へ… (96). Unnamespaced, the Japanese row overwrites
  /// the English one and flips its printed total, breaking set completion for existing users.
  it("keeps the four colliding set ids apart", () => {
    for (const id of ["neo1", "neo2", "neo3", "neo4"]) {
      expect(jaSetId(id)).toBe(`ja-${id}`);
      expect(jaSetId(id)).not.toBe(id);
    }
  });

  /// Unconditional, not just on the four known collisions — TCGdex adds sets over time and a
  /// future collision must not be able to reach production.
  it("namespaces every set, not only the ones that collide today", () => {
    expect(jaSetId("SV1a")).toBe("ja-SV1a");
    expect(jaSetId("PMCG1")).toBe("ja-PMCG1");
  });

  it("is idempotent, so a re-read cache never double-prefixes", () => {
    expect(jaSetId(jaSetId("neo1"))).toBe("ja-neo1");
  });

  /// `FlatCard.id === `${setId}-${localId}`` is what every `card.set_id` join relies on. Prefixing
  /// the whole card id instead of its set would break that invariant while looking identical.
  it("builds card ids from the namespaced SET", () => {
    expect(jaCardId("SV1a", "001")).toBe("ja-SV1a-001");
    const card = toFlatCard("SV1a", sampleCard());
    expect(card.id).toBe(`${card.setId}-${card.localId}`);
  });

  /// Card ids happen not to collide today only because the zero-padding differs (`neo1-1` vs
  /// `neo1-001`). That is luck, and this asserts we don't depend on it.
  it("separates card ids that would otherwise be indistinguishable", () => {
    expect(jaCardId("neo1", "1")).toBe("ja-neo1-1");
    expect(collidingIds(["neo1-1"], [jaCardId("neo1", "1")])).toEqual([]);
  });

  it("reports a collision when one exists, so the build can refuse", () => {
    expect(collidingIds(["neo1", "base1"], ["ja-neo1"])).toEqual([]);
    // The guard has to actually fire — an assertion that can never fail is worse than none.
    expect(collidingIds(["neo1", "base1"], ["neo1"])).toEqual(["neo1"]);
  });

  it("recognises a Japanese id after the fact", () => {
    expect(isJapanese("ja-neo1-001")).toBe(true);
    expect(isJapanese("neo1-1")).toBe(false);
  });
});

describe("Japanese card ingest", () => {
  it("carries EUR on the card, because there is no cardmarket id to join on", () => {
    const card = toFlatCard("SV1a", sampleCard());
    expect(card.lang).toBe("ja");
    expect(card.rawEur).toBe(0.06);
    expect(card.cardmarketIds).toEqual([]);
    expect(card.tcgplayerIds).toEqual([]);   // JA cards have a null tcgplayer block — verified live
    expect(card.imageBase).toBe("https://assets.tcgdex.net/ja/SV/SV1a/001");
  });

  it("converts EUR to USD at the given rate", () => {
    const card = toFlatCard("SV1a", sampleCard());
    expect(jaRawUsd(card, { rate: 1.138, date: "2026-07-29" })).toBe(0.07);
  });

  /// A Japanese card with no cardmarket trend (most old sets have none) must stay unpriced rather
  /// than become $0.00, which would drag portfolio totals and set-value averages down silently.
  it("leaves an unpriced Japanese card unpriced", () => {
    const card = toFlatCard("neo1", { ...sampleCard(), rawEur: null });
    expect(jaRawUsd(card, { rate: 1.138, date: "2026-07-29" })).toBeNull();
  });

  it("maps a set into the same shape the English flatten emits", () => {
    const set: TcgdexSet = {
      id: "neo1", name: "金、銀、新世界へ...", releaseDate: "2000-10-01",
      cardCountTotal: 96, printedTotal: 96, serie: "Neo",
    };
    expect(toFlatSet(set)).toEqual({
      id: "ja-neo1", name: "金、銀、新世界へ...", releaseDate: "2000-10-01",
      serie: "Neo", official: 96, printedTotal: 96,
    });
  });
});

function sampleCard(): TcgdexCard {
  return {
    id: "SV1a-001", localId: "001", name: "トロピウス", hp: 110,
    types: ["Grass"], rarity: "Common", artist: "sui", text: "",
    attacks: [], imageBase: "https://assets.tcgdex.net/ja/SV/SV1a/001",
    rawUsd: null, rawEur: 0.06,
  };
}
