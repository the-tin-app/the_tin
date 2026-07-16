import { detectGradedHistoryMode, type GradedHistoryMode } from "./ppt-graded";

export interface ProbeClient {
  getSetEnrichment(setName: string): Promise<{ ebayRaw: unknown }[]>;
  getPopulation(tcgPlayerIds: number[]): Promise<unknown>;
  lastHeaders: { minuteLimit: number; minuteRemaining: number; purchasedRemaining: number; dailyRemaining: number };
}

export interface ProbeResult {
  minuteLimit: number;
  purchasedRemaining: number;
  gradedHistoryMode: GradedHistoryMode;
  populationEnabled: boolean;
  probedAt: string;
}

export async function runProbe(
  client: ProbeClient,
  sampleSetName: string,
  sampleTcgPlayerId: number | null,
  nowIso: string,
): Promise<ProbeResult> {
  const cards = await client.getSetEnrichment(sampleSetName);
  const gradedHistoryMode = detectGradedHistoryMode(cards[0]?.ebayRaw);
  const { minuteLimit, purchasedRemaining } = client.lastHeaders;

  let populationEnabled = false;
  if (sampleTcgPlayerId == null) {
    // No tcgplayer_id available in the catalog to probe with — population can't run at all, so skip the check.
    populationEnabled = false;
  } else {
    try {
      await client.getPopulation([sampleTcgPlayerId]);
      populationEnabled = true;
    } catch (e) {
      if (!/PPT 403/.test((e as Error)?.message ?? "")) throw e; // only a plan-lockout 403 is expected/swallowed
      populationEnabled = false;
    }
  }

  return { minuteLimit, purchasedRemaining, gradedHistoryMode, populationEnabled, probedAt: nowIso };
}
