import assert from "node:assert/strict";
import zlib from "node:zlib";
import { renderListHTML, renderErrorHTML, decodePayload, base64urlToBytes } from "../functions/l.js";

function encode(payload) {
  const gz = zlib.gzipSync(Buffer.from(JSON.stringify(payload), "utf8"), { level: 9 });
  return gz.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

const origin = "https://thetinapp.com";

// --- decoding -------------------------------------------------------------

const wantPayload = {
  v: 1,
  k: "want",
  i: [
    { c: "base1-4", n: "Charizard", s: "Base Set", p: "high", t: 250 },
    { c: "swsh7-215", n: "Rayquaza VMAX", s: "Evolving Skies" },
  ],
};
assert.deepEqual(await decodePayload(encode(wantPayload)), wantPayload, "round-trips a want list");

// base64url padding is stripped at all four remainders; decoding must restore it
for (let n = 1; n <= 8; n++) {
  const bytes = new Uint8Array(n).fill(0xab);
  const b64url = Buffer.from(bytes).toString("base64")
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  assert.deepEqual([...base64urlToBytes(b64url)], [...bytes], `padding restored for ${n} bytes`);
}

// Garbage must reject, not throw something unhandled or render a half-page
await assert.rejects(() => decodePayload("not-a-payload"), "garbage rejected");
// Valid gzip, wrong shape (no items array)
await assert.rejects(() => decodePayload(encode({ v: 1, k: "want" })), "shape validated");

// --- rendering ------------------------------------------------------------

const wantHTML = renderListHTML({ payload: wantPayload, origin });
assert.ok(wantHTML.includes("2 cards wanted"), "headline counts the cards");
assert.ok(wantHTML.includes("Charizard") && wantHTML.includes("Base Set"), "names and sets shown");
assert.ok(wantHTML.includes("target $250.00"), "want target rendered");
assert.ok(wantHTML.includes('class="pri high"'), "priority rendered");

const tradeHTML = renderListHTML({
  payload: { v: 1, k: "trade", i: [{ c: "base1-4", n: "Charizard", s: "Base Set", q: 3, d: "NM" }] },
  origin,
});
assert.ok(tradeHTML.includes("1 card up for trade"), "trade headline, singular");
assert.ok(tradeHTML.includes("×3") && tradeHTML.includes("NM"), "quantity and condition shown");

// A card with no name still renders (falls back to the id) rather than printing "undefined"
const bareHTML = renderListHTML({ payload: { v: 1, k: "want", i: [{ c: "sv1-25" }] }, origin });
assert.ok(bareHTML.includes("sv1-25"), "falls back to the card id");
assert.ok(!bareHTML.includes("undefined"), "no undefined leaks into the page");

// --- privacy --------------------------------------------------------------

// The page must never index, and must not be cached by an intermediary.
assert.ok(wantHTML.includes('name="robots" content="noindex, nofollow"'), "noindex meta present");
// og:image is our own static asset — there is no per-user image to leak.
assert.ok(wantHTML.includes(`content="${origin}/assets/icon-512.png"`), "static og:image");

// --- escaping -------------------------------------------------------------

const nastyHTML = renderListHTML({
  payload: { v: 1, k: "want", i: [{ c: "x", n: '<script>alert(1)</script>', s: '" onload="x' }] },
  origin,
});
assert.ok(!nastyHTML.includes("<script>alert(1)</script>"), "card name is escaped");
assert.ok(nastyHTML.includes("&lt;script&gt;"), "escaped entity present");
assert.ok(!nastyHTML.includes('" onload="x'), "set name can't break out of an attribute");

// --- errors ---------------------------------------------------------------

const errorHTML = renderErrorHTML({ origin });
assert.ok(errorHTML.includes("isn't readable"), "error page explains itself");
assert.ok(errorHTML.includes('content="noindex, nofollow"'), "error page is noindex too");

console.log("shared-list: all assertions passed");
