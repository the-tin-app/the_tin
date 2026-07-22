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

export function renderCardHTML({ id, name, set, img, origin }) {
  const title = [name, set].filter(Boolean).join(" · ") || "The Tin";
  const canonical = `${origin}/c/${encodeURIComponent(id)}`;
  const ogImage = img ? `<meta property="og:image" content="${esc(img)}">` : "";
  const cardArt = img ? `<img class="art" src="${esc(img)}" alt="${esc(name)}">` : "";
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
  .set{color:#aeb9d4;margin:0 0 22px}
  .cta{display:inline-block;background:#f4c542;color:#12213f;font-weight:600;
       text-decoration:none;padding:12px 20px;border-radius:10px}
  .foot{margin-top:16px;font-size:.8rem;color:#8794b4}
  .foot a{color:#aeb9d4}
</style>
</head>
<body>
<main class="card">
  ${cardArt}
  <h1>${esc(name || "A Pokémon card")}</h1>
  <p class="set">${esc(set)}</p>
  <a class="cta" href="${esc(origin)}/">Coming to the App Store</a>
  <p class="foot">Shared from <a href="${esc(origin)}/">The Tin</a> — free, open-source Pokémon TCG tracker.</p>
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
  });
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}
