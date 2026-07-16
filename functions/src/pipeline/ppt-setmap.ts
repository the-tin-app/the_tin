export interface PptSetInfo {
  name: string;
  slug: string;
  series: string;
  releaseDate: string | null;
}

export interface OurSet {
  id: string;
  name: string;
  releaseDate: string | null;
}

/**
 * Curated, hand-audited overrides for sets whose PPT name can't be derived from ours by
 * name/date heuristics (verified against the live PPT /sets list, 2026-07-07). Maps our
 * catalog set_id → the exact PPT set name. Trainer kits map BOTH our halves onto PPT's
 * single combined set. Sets PPT genuinely lacks (e.g. Paldean Wonders, Scarlet & Violet
 * Energy) are intentionally absent — they stay unmatched.
 */
export const PPT_SET_ALIASES: Record<string, string> = {
  // Black Star Promos → PPT "<era> Promos"
  mep: "ME: Mega Evolution Promo",
  svp: "SV: Scarlet & Violet Promo Cards",
  swshp: "SWSH: Sword & Shield Promo Cards",
  smp: "SM Promos",
  xyp: "XY Promos",
  bwp: "Black and White Promos",
  hgssp: "HGSS Promos",
  dpp: "Diamond and Pearl Promos",
  np: "Nintendo Promos",
  basep: "WoTC Promo",
  bog: "Best of Promos",
  // Energies
  mee: "MEE: Mega Evolution Energies",
  // McDonald's Collection → "McDonald's Promos YYYY"
  "2024sv": "McDonald's Promos 2024",
  "2023sv": "McDonald's Promos 2023",
  "2022swsh": "McDonald's Promos 2022",
  "2021swsh": "McDonald's 25th Anniversary Promos",
  "2019sm": "McDonald's Promos 2019",
  "2018sm": "McDonald's Promos 2018",
  "2017sm": "McDonald's Promos 2017",
  "2016xy": "McDonald's Promos 2016",
  "2015xy": "McDonald's Promos 2015",
  "2014xy": "McDonald's Promos 2014",
  "2012bw": "McDonald's Promos 2012",
  "2011bw": "McDonald's Promos 2011",
  // Trainer Kits (PPT combines both halves into one set)
  "tk-sm-l": "SM Trainer Kit: Lycanroc & Alolan Raichu",
  "tk-sm-r": "SM Trainer Kit: Lycanroc & Alolan Raichu",
  "tk-xy-p": "XY Trainer Kit: Pikachu Libre & Suicune",
  "tk-xy-su": "XY Trainer Kit: Pikachu Libre & Suicune",
  "tk-xy-latia": "XY Trainer Kit: Latias & Latios",
  "tk-xy-latio": "XY Trainer Kit: Latias & Latios",
  "tk-xy-b": "XY Trainer Kit: Bisharp & Wigglytuff",
  "tk-xy-w": "XY Trainer Kit: Bisharp & Wigglytuff",
  "tk-xy-sy": "XY Trainer Kit: Sylveon & Noivern",
  "tk-xy-n": "XY Trainer Kit: Sylveon & Noivern",
  "tk-bw-e": "BW Trainer Kit: Excadrill & Zoroark",
  "tk-bw-z": "BW Trainer Kit: Excadrill & Zoroark",
  "tk-hs-g": "HGSS Trainer Kit: Gyarados & Raichu",
  "tk-hs-r": "HGSS Trainer Kit: Gyarados & Raichu",
  "tk-dp-l": "DP Trainer Kit: Manaphy & Lucario",
  "tk-dp-m": "DP Trainer Kit: Manaphy & Lucario",
  "tk-ex-m": "EX Trainer Kit 2: Plusle & Minun",
  "tk-ex-p": "EX Trainer Kit 2: Plusle & Minun",
  "tk-ex-latia": "EX Trainer Kit 1: Latias & Latios",
  "tk-ex-latio": "EX Trainer Kit 1: Latias & Latios",
};

function norm(n: string): string {
  return n.toLowerCase().replace(/[^a-z0-9]/g, "");
}
function day(d: string | null): string | null {
  return d ? d.slice(0, 10) : null;
}
function year(d: string | null): string | null {
  return d ? d.slice(0, 4) : null;
}
function nameRelated(a: string, b: string): boolean {
  return a.length > 0 && b.length > 0 && (a.includes(b) || b.includes(a));
}

/**
 * Resolve our catalog set to a PPT set, deterministically and auditably.
 * Tiers, in order:
 *   1. exact normalized-name match;
 *   2. exact release-DATE match (PPT dates are far more reliable than its set names) —
 *      if one PPT set shares the date, take it; if several, take the one whose name is
 *      related (contains/contained), else null (ambiguous → never guess);
 *   3. name-contains with the same release YEAR;
 *   4. else null.
 */
export function resolvePptSetName(ourSet: OurSet, pptSets: PptSetInfo[]): PptSetInfo | null {
  // Tier 0: curated alias wins outright. If the aliased PPT set isn't in the list, that's a
  // genuine miss (do NOT fall through to a heuristic guess for a set we've explicitly mapped).
  const alias = PPT_SET_ALIASES[ourSet.id];
  if (alias != null) return pptSets.find((p) => p.name === alias) ?? null;

  const on = norm(ourSet.name);

  const exact = pptSets.find((p) => norm(p.name) === on);
  if (exact) return exact;

  const od = day(ourSet.releaseDate);
  if (od) {
    const sameDay = pptSets.filter((p) => day(p.releaseDate) === od);
    if (sameDay.length === 1) return sameDay[0];
    if (sameDay.length > 1) {
      const related = sameDay.find((p) => nameRelated(norm(p.name), on));
      if (related) return related;
      // multiple sets share the date and none is name-related — ambiguous, don't guess.
    }
  }

  const oy = year(ourSet.releaseDate);
  const contained = pptSets.find((p) => norm(p.name).includes(on) && oy != null && year(p.releaseDate) === oy);
  return contained ?? null;
}
