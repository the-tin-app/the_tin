/**
 * How much of the Japanese catalogue is actually usable — art and price coverage per set.
 *
 *   npx tsx scripts/probe-ja-coverage.ts          # sample one card per set (~355 req, <1 min)
 *   npx tsx scripts/probe-ja-coverage.ts --full   # every card (~16k req, ~40 min)
 *
 * Same role as `probe-ppt-coverage.ts`: answer "is this data good enough to ship" before
 * committing the pipeline to it, and stay runnable so the answer can be re-checked as TCGdex
 * fills gaps. Deliberately plain `fetch` rather than `TcgdexClient` — the client's `getSetCards`
 * reads every card, which is the exact cost the sampled mode exists to avoid.
 *
 * ⚠️ Sampled mode is a proxy, not a census: a set whose FIRST card lacks art may still have art
 * further in. Treat a sampled zero as "worth a `--full` look", not as proof.
 *
 * ## What it said on 2026-07-29
 *
 * Sampled: **28 of 177 sets had art on card #1.** Full reads of four sets:
 *
 *   SV1a   103 cards  images 100%  EUR 39%
 *   s12a   254 cards  images 100%  EUR 46%
 *   neo1    96 cards  images   0%  EUR  0%
 *   PMCG1  102 cards  images   0%  EUR  0%
 *
 * So coverage is patchy rather than simply old-vs-new — SV11W/SV11B and the 2026 Mega Evolution
 * sets sampled artless too. That is a product question, not a pipeline one: The Tin is a visual
 * app, and a set whose every tile is a placeholder browses very differently from one that isn't.
 * Recorded here rather than decided in code.
 */
const ROOT = "https://api.tcgdex.net/v2/ja";

async function getJson(path: string): Promise<any> {
  const res = await fetch(`${ROOT}${path}`);
  if (!res.ok) throw new Error(`TCGdex ${res.status} for ${path}`);
  return res.json();
}

async function main() {
  const full = process.argv.includes("--full");
  const sets: any[] = await getJson("/sets");
  const rows: { id: string; cards: number; img: number; eur: number; sampled: boolean }[] = [];

  for (const s of sets) {
    const total = s.cardCount?.total ?? 0;
    if (total === 0) continue;
    try {
      const briefs: any[] = (await getJson(`/sets/${s.id}`)).cards ?? [];
      const pick = full ? briefs : briefs.slice(0, 1);
      let img = 0, eur = 0;
      for (const b of pick) {
        const c = await getJson(`/cards/${b.id}`);
        if (c.image) img++;
        if (typeof c.pricing?.cardmarket?.trend === "number") eur++;
      }
      rows.push({ id: s.id, cards: full ? pick.length : total, img, eur, sampled: !full });
    } catch (err) {
      console.log(`[ja-cov] WARN ${s.id}: ${String(err)}`);
    }
  }

  const denom = (r: typeof rows[number]) => (r.sampled ? 1 : r.cards);
  for (const r of rows) {
    const pct = (n: number) => `${Math.round((100 * n) / denom(r))}%`;
    console.log(`${r.id.padEnd(8)} ${String(r.cards).padStart(5)} cards  images ${pct(r.img).padStart(4)}  EUR ${pct(r.eur).padStart(4)}${r.sampled ? "  (sampled)" : ""}`);
  }

  const artless = rows.filter((r) => r.img === 0);
  console.log(`\nsets: ${rows.length}   cards: ${rows.reduce((n, r) => n + r.cards, 0)}`);
  console.log(`sets with NO art: ${artless.length} (${artless.reduce((n, r) => n + r.cards, 0)} cards)`);
  console.log(artless.map((r) => `${r.id}(${r.cards})`).join(" "));
}

main().catch((e) => { console.error(e); process.exit(1); });
