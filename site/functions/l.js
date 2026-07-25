// Cloudflare Pages Function: GET /l?d=<payload>
// Renders a shared want list or trade list from the URL alone.
//
// PRIVACY CONTRACT (mirrors ios/.../ShareList.swift — change both or neither):
//   * The payload holds the CARDS only: id, name, set name, plus a target price / priority for a
//     want list and a quantity / condition for a trade list.
//   * It holds NO user id, device id, install id, account, handle, contact line, timestamp,
//     location, or collection total. Two people sharing the same cards produce identical links.
//   * NOTHING IS STORED. There is no database, no upload, no account — this function renders from
//     the query string and forgets. "Deleting" a shared list means not sharing the link again.
//   * The route is noindex (see the response headers below) so shared lists never enter a search
//     index. It IS edge-cacheable: the URL already carries the whole list, so a cached copy is
//     only readable by someone who already has the link, and caching keeps repeat views (unfurl
//     crawlers especially) off the Workers invocation count.
//
// The payload is in the query string rather than a #fragment because a fragment never reaches the
// server — strictly more private, but Facebook and Discord crawlers can't read one either, and the
// post would unfurl as a blank box. Posting to those is the entire point of the feature.
//
// Encoding: JSON -> gzip -> base64url. `DecompressionStream` is available in Workers and in every
// browser we care about, so no library is needed on either side.

function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function base64urlToBytes(s) {
  const padded = s.replaceAll("-", "+").replaceAll("_", "/");
  const full = padded + "=".repeat((4 - (padded.length % 4)) % 4);
  const binary = atob(full);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function decodePayload(encoded) {
  const stream = new Blob([base64urlToBytes(encoded)])
    .stream()
    .pipeThrough(new DecompressionStream("gzip"));
  const json = await new Response(stream).text();
  const payload = JSON.parse(json);
  if (!payload || !Array.isArray(payload.i)) throw new Error("malformed payload");
  return payload;
}

function money(n) {
  return `$${Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** One row. Wants show a target price; trades show quantity and condition. */
function renderItem(item, kind) {
  const name = esc(item.n || item.c);
  const set = item.s ? `<span class="set">${esc(item.s)}</span>` : "";
  const meta = [];
  if (kind === "trade") {
    if (item.q > 1) meta.push(`×${esc(item.q)}`);
    if (item.d) meta.push(esc(item.d));
  } else {
    if (item.p) meta.push(`<span class="pri ${esc(item.p)}">${esc(item.p)}</span>`);
    if (typeof item.t === "number") meta.push(`target ${esc(money(item.t))}`);
  }
  return `<li><span class="nm">${name}</span>${set}<span class="meta">${meta.join(" · ")}</span></li>`;
}

export function renderListHTML({ payload, origin }) {
  const kind = payload.k === "trade" ? "trade" : "want";
  const count = payload.i.length;
  const noun = count === 1 ? "card" : "cards";
  const title = kind === "trade" ? `${count} ${noun} up for trade` : `${count} ${noun} wanted`;
  const description =
    kind === "trade"
      ? "A trade list shared from The Tin — a free, open-source Pokémon TCG collection tracker."
      : "A want list shared from The Tin — a free, open-source Pokémon TCG collection tracker.";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} — The Tin</title>
<meta name="robots" content="noindex, nofollow">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${esc(origin)}/assets/icon-512.png">
<meta name="twitter:card" content="summary">
<meta name="theme-color" content="#12213f">
<link rel="icon" href="/assets/favicon.png" type="image/png">
<style>
  body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#12213f;color:#f4f6fb;
       min-height:100vh;padding:32px 20px;display:flex;justify-content:center}
  main{width:100%;max-width:520px}
  h1{font-size:1.5rem;margin:0 0 2px}
  .sub{color:#8794b4;font-size:.85rem;margin:0 0 22px}
  ul{list-style:none;padding:0;margin:0 0 24px}
  li{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;
     padding:10px 0;border-bottom:1px solid rgba(255,255,255,.08)}
  .nm{font-weight:600}
  .set{color:#aeb9d4;font-size:.85rem}
  .meta{margin-left:auto;color:#aeb9d4;font-size:.85rem;font-variant-numeric:tabular-nums}
  .pri.high{color:#ff8a80;font-weight:600}
  .pri.low{color:#8794b4}
  .cta{display:inline-block;background:#f4c542;color:#12213f;font-weight:600;
       text-decoration:none;padding:12px 20px;border-radius:10px}
  .foot{margin-top:18px;font-size:.8rem;color:#8794b4;line-height:1.5}
  .foot a{color:#aeb9d4}
</style>
</head>
<body>
<main>
  <h1>${esc(title)}</h1>
  <p class="sub">Shared from The Tin</p>
  <ul>${payload.i.map((item) => renderItem(item, kind)).join("")}</ul>
  <a class="cta" href="${esc(origin)}/">Get The Tin</a>
  <p class="foot">This list lives entirely in the link — nothing was uploaded, and it says nothing
  about who shared it. <a href="${esc(origin)}/">The Tin</a> is a free, open-source Pokémon TCG
  collection tracker.</p>
</main>
</body>
</html>`;
}

export function renderErrorHTML({ origin }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Link not readable — The Tin</title>
<meta name="robots" content="noindex, nofollow">
<style>
  body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#12213f;color:#f4f6fb;
       min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;
       text-align:center}
  a{color:#f4c542}
</style>
</head>
<body>
<main>
  <h1>This link isn't readable</h1>
  <p>It may have been cut short when it was pasted — shared lists carry their whole contents in the
  link, so a truncated one can't be recovered. Ask for a fresh one.</p>
  <p><a href="${esc(origin)}/">The Tin</a></p>
</main>
</body>
</html>`;
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const encoded = url.searchParams.get("d");
  // Cacheable like /c/:id. A cache entry is keyed by the full URL, and that URL already contains
  // the list — so caching exposes nothing to anyone who couldn't already read it, and it stops a
  // popular link billing an invocation per unfurl. Still noindex: cacheable is not findable.
  const headers = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "public, max-age=3600",
    "x-robots-tag": "noindex, nofollow",
  };
  if (!encoded) return new Response(renderErrorHTML({ origin: url.origin }), { status: 400, headers });
  try {
    const payload = await decodePayload(encoded);
    return new Response(renderListHTML({ payload, origin: url.origin }), { headers });
  } catch {
    return new Response(renderErrorHTML({ origin: url.origin }), { status: 400, headers });
  }
}
