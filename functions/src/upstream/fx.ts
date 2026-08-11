import type { FetchFn } from "./tcgdex";

/** A EUR→USD reference rate and the day the ECB published it. */
export interface FxRate {
  /** USD per 1 EUR. */
  rate: number;
  /** ECB publication date, `YYYY-MM-DD`. NOT the day we fetched it — see below. */
  date: string;
}

export const ECB_DAILY_URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml";

/**
 * Pull `time` and the USD rate out of the ECB's daily reference file (~1.5 KB, no key, no rate
 * limit). Deliberately a regex over two attributes rather than an XML parser: the file is a
 * fixed-shape feed the ECB has published unchanged for twenty years, and a parser dependency to
 * read two attributes is a dependency to keep patched forever.
 *
 * Throws when either is missing. A missing rate MUST be an error, never a fallback: there is no
 * safe default here — a silently wrong FX rate misprices an entire catalogue, and unlike a
 * missing one, nothing downstream would notice.
 */
export function parseEcbDaily(xml: string): FxRate {
  const date = /time=['"]([0-9]{4}-[0-9]{2}-[0-9]{2})['"]/.exec(xml)?.[1];
  const rate = /currency=['"]USD['"]\s+rate=['"](-?[0-9.]+)['"]/.exec(xml)?.[1];
  if (!date) throw new Error("ECB feed: no time attribute");
  if (!rate) throw new Error("ECB feed: no USD rate");
  const value = Number(rate);
  // A zero or negative rate would zero every Japanese price rather than fail. Refuse it.
  if (!Number.isFinite(value) || value <= 0) throw new Error(`ECB feed: implausible USD rate ${rate}`);
  return { rate: value, date };
}

/**
 * ⚠️ The ECB publishes on **business days only**, so a weekend or holiday run gets Friday's file
 * with Friday's `time`. That is success, not failure — a *stale but present* rate is fine and a
 * *missing* one is fatal. Treating staleness as an error would halt the nightly every bank
 * holiday, which is why `date` is carried through to the artifact instead of being checked here.
 */
export async function fetchEurUsd(fetchFn: FetchFn = fetch): Promise<FxRate> {
  const res = await fetchFn(ECB_DAILY_URL);
  if (!res.ok) throw new Error(`ECB ${res.status}`);
  return parseEcbDaily(await res.text());
}

/** EUR price → USD, rounded to cents. Null in, null out — an unpriced card stays unpriced. */
export function eurToUsd(eur: number | null | undefined, fx: FxRate): number | null {
  if (typeof eur !== "number" || !Number.isFinite(eur)) return null;
  return Math.round(eur * fx.rate * 100) / 100;
}
