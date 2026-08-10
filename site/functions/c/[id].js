// Cloudflare Pages Function: GET /c/:id
// Renders per-card Open Graph tags from the query string the app writes at share time.
// No catalog lookup — the share URL carries name/set/img, so this stays public & stateless.

function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

// A printed label's `p` and `c` (see LabelPayload.swift). These maps are the SANITISER, not a
// convenience: both values arrive from a URL anyone can write, so a value that isn't a key is
// DROPPED rather than escaped-and-shown — the page can never display a string someone else chose.
// Keys are CardVariant / CardCondition rawValues and are a public contract; only ever add.
const PRINTINGS = {
  regular: "Regular",
  holo: "Holo",
  reverseHolo: "Reverse Holo",
  firstEdition: "1st Edition",
};
const CONDITIONS = { NM: "NM", LP: "LP", MP: "MP", HP: "HP", DMG: "DMG" };

export function renderCardHTML({ id, name, set, img, origin, printing, condition }) {
  const title = [name, set].filter(Boolean).join(" · ") || "The Tin";
  const canonical = `${origin}/c/${encodeURIComponent(id)}`;
  const ogImage = img ? `<meta property="og:image" content="${esc(img)}">` : "";
  const cardArt = img ? `<img class="art" src="${esc(img)}" alt="${esc(name)}">` : "";
  // What the sticker says about this particular copy. Absent for a plain share link, and absent
  // for a label whose values we don't recognise — the card itself still renders either way.
  const copy = [PRINTINGS[printing], CONDITIONS[condition]].filter(Boolean).join(" · ");
  const copyLine = copy ? `<p class="copy">${esc(copy)}</p>` : "";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} — The Tin</title>
<link rel="canonical" href="${esc(canonical)}">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="Shared from The Tin — a free, open-source Pokémon TCG collection tracker.">
<meta property="og:url" content="${esc(canonical)}">
${ogImage}
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#12213f">
<link rel="icon" href="/assets/favicon.png" type="image/png">
<style>
  body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#12213f;color:#f4f6fb;
       min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
  .card{max-width:360px;text-align:center}
  .art{width:100%;max-width:280px;border-radius:12px;box-shadow:0 8px 30px rgba(0,0,0,.4)}
  h1{font-size:1.4rem;margin:18px 0 4px}
  .meta{margin:0 0 22px}
  .set{color:#aeb9d4;margin:0}
  .copy{color:#f4c542;font-weight:600;margin:4px 0 0;font-size:.95rem}
  .cta{display:inline-block;background:#f4c542;color:#12213f;font-weight:600;
       text-decoration:none;padding:12px 20px;border-radius:10px}
  .foot{margin-top:16px;font-size:.8rem;color:#8794b4}
  .foot a{color:#aeb9d4}
</style>
</head>
<body>
<main class="card">
  ${cardArt}
  <h1>${esc(name || "A trading card")}</h1>
  <div class="meta"><p class="set">${esc(set)}</p>${copyLine}</div>
  <a class="cta" href="https://apps.apple.com/app/id6788516920">Download on the App Store</a>
  <p class="foot">Shared from <a href="${esc(origin)}/">The Tin</a> — free, open-source TCG card tracker.</p>
</main>
</body>
</html>`;
}

export function onRequest(context) {
  const url = new URL(context.request.url);
  const html = renderCardHTML({
    id: context.params.id,
    name: url.searchParams.get("n") || "",
    set: url.searchParams.get("set") || "",
    img: url.searchParams.get("img") || "",
    origin: url.origin,
    // From a printed label. `v` and `e` are deliberately ignored: the format version means
    // nothing to a stateless page, and an entry id is device-local and can never resolve here.
    printing: url.searchParams.get("p") || "",
    condition: url.searchParams.get("c") || "",
  });
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}
