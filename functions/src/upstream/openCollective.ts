export interface OcStats {
  raisedThisMonthCents: number;
  balanceCents: number;
}

export type FetchLike = (url: string, init?: {
  method?: string; headers?: Record<string, string>; body?: string;
}) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

const QUERY = `
query($slug: String!, $dateFrom: DateTime!) {
  account(slug: $slug) {
    stats {
      balance { valueInCents }
      totalAmountReceived(dateFrom: $dateFrom) { valueInCents }
    }
  }
}`;

export async function fetchOcStats(slug: string, monthStartIso: string, fetchFn: FetchLike): Promise<OcStats> {
  const res = await fetchFn("https://api.opencollective.com/graphql/v2", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query: QUERY, variables: { slug, dateFrom: monthStartIso } }),
  });
  if (!res.ok) throw new Error(`Open Collective API error: ${res.status}`);
  const payload = (await res.json()) as {
    data?: { account?: { stats?: {
      balance?: { valueInCents?: number };
      totalAmountReceived?: { valueInCents?: number };
    } } | null };
  };
  const account = payload.data?.account;
  if (!account) throw new Error(`Open Collective account not found: ${slug}`);
  return {
    balanceCents: account.stats?.balance?.valueInCents ?? 0,
    raisedThisMonthCents: account.stats?.totalAmountReceived?.valueInCents ?? 0,
  };
}
