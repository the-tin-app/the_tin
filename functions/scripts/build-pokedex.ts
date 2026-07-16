/**
 * Generate functions/data/pokedex.json (National Dex id -> English display name)
 * from the public PokéAPI species list. One-time / occasional operator run.
 *   npx tsx scripts/build-pokedex.ts [limit=1025]
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";

export function normalizeSpeciesName(slug: string): string {
  return slug.split("-").map((s) => (s ? s[0].toUpperCase() + s.slice(1) : s)).join("-");
}

async function main() {
  const limit = Number(process.argv[2] ?? 1025);
  const res = await fetch(`https://pokeapi.co/api/v2/pokemon-species?limit=${limit}`);
  if (!res.ok) throw new Error(`PokéAPI ${res.status}`);
  const body: any = await res.json();
  const map: Record<string, string> = {};
  for (const r of body.results as { name: string; url: string }[]) {
    const m = r.url.match(/\/pokemon-species\/(\d+)\//);
    if (m) map[m[1]] = normalizeSpeciesName(r.name);
  }
  const out = join(__dirname, "../data/pokedex.json");
  writeFileSync(out, JSON.stringify(map, null, 0));
  console.log(`wrote ${Object.keys(map).length} species → ${out}`);
}
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
