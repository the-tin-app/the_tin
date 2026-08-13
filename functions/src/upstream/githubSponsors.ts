/**
 * GitHub Sponsors totals for the funding meter. Replaces the Open Collective client — Open Source
 * Collective rejected the project on 2026-07-25 and GitHub Sponsors is the only platform.
 *
 * Two fields, one round-trip:
 *  - `monthlyEstimatedSponsorsIncomeInCents` — recurring monthly income. **Masked to 0 for anyone
 *    who isn't the maintainer** (verified: a user with 178 public sponsors reads 0 through a
 *    non-maintainer token), so the meter silently reads $0 forever rather than erroring if the
 *    nightly's token can't see the listing. For a USER listing the token owner is the sponsorable
 *    itself, so a plain PAT suffices; an ORG listing needs an org-admin token.
 *  - `sponsorsListing.activeGoal` — the goal configured on the Sponsors page itself, so the meter's
 *    denominator follows the page instead of drifting from a hardcoded constant.
 *
 * Scope: a classic PAT with `read:org` is enough for both (verified 2026-07-25) and is REQUIRED
 * only while the listing lives on an organisation. No sponsors-specific scope exists; `read:user`
 * is only needed for per-sponsor `privacyLevel`, which we deliberately don't read — the Supporters
 * list is hand-curated, see `refresh-funding.ts`.
 */
export interface SponsorsStats {
  monthlyIncomeCents: number;
  /** Monthly-amount goal in cents, when the listing has one active. Null ⇒ caller's fallback. */
  goalCents: number | null;
}

export type FetchLike = (url: string, init?: {
  method?: string; headers?: Record<string, string>; body?: string;
}) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

// `repositoryOwner` + an `on Sponsorable` fragment resolves a USER or an ORGANISATION with no
// branching — `organization(login:)` returns null for a user login, which threw "not found" and
// left the meter permanently unpopulated. Verified against both shapes 2026-08-12.
const QUERY = `
query($login: String!) {
  repositoryOwner(login: $login) {
    ... on Sponsorable {
      monthlyEstimatedSponsorsIncomeInCents
      sponsorsListing {
        activeGoal { kind targetValue }
      }
    }
  }
}`;

export async function fetchSponsorsStats(
  login: string, token: string, fetchFn: FetchLike,
): Promise<SponsorsStats> {
  const res = await fetchFn("https://api.github.com/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      "User-Agent": "the-tin-nightly", // GitHub rejects UA-less API requests
    },
    body: JSON.stringify({ query: QUERY, variables: { login } }),
  });
  if (!res.ok) throw new Error(`GitHub API error: ${res.status}`);
  const payload = (await res.json()) as {
    errors?: { message?: string }[];
    data?: { repositoryOwner?: {
      monthlyEstimatedSponsorsIncomeInCents?: number;
      sponsorsListing?: { activeGoal?: { kind?: string; targetValue?: number } | null } | null;
    } | null };
  };
  // GraphQL reports auth/scope problems as a 200 with an `errors` array — surface them as failures
  // so the nightly's non-fatal warning fires instead of writing a bogus $0.
  if (payload.errors?.length) throw new Error(`GitHub API error: ${payload.errors[0]?.message}`);
  const owner = payload.data?.repositoryOwner;
  if (!owner) throw new Error(`GitHub sponsorable not found: ${login}`);
  const goal = owner.sponsorsListing?.activeGoal;
  // targetValue is whole dollars for MONTHLY_SPONSORSHIP_AMOUNT; a TOTAL_SPONSORS_COUNT goal is a
  // headcount and would make a nonsense denominator, so it falls through to the caller's default.
  const goalCents = goal?.kind === "MONTHLY_SPONSORSHIP_AMOUNT" && typeof goal.targetValue === "number"
    ? Math.round(goal.targetValue * 100)
    : null;
  return { monthlyIncomeCents: owner.monthlyEstimatedSponsorsIncomeInCents ?? 0, goalCents };
}
