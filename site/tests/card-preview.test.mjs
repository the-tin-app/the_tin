import assert from "node:assert/strict";
import { renderCardHTML } from "../functions/c/[id].js";

const html = renderCardHTML({
  id: "base1-4",
  name: 'Charizard "First" & <friends>',
  set: "Base Set",
  img: "https://cdn.example.com/base1-4/high.webp",
  origin: "https://thetinapp.com",
});

// OG image points at the supplied public CDN url
assert.ok(html.includes('property="og:image" content="https://cdn.example.com/base1-4/high.webp"'), "og:image present");
// Title carries name + set
assert.ok(html.includes("Charizard") && html.includes("Base Set"), "title has name and set");
// Raw angle brackets / quotes from input are escaped, never emitted literally in an attribute
assert.ok(!html.includes("<friends>"), "input HTML-escaped");
assert.ok(html.includes("&lt;friends&gt;"), "escaped entity present");
// Install CTA points at the live listing (approved 2026-07-31); footer still links home
assert.ok(html.includes("Download on the App Store"), "install CTA copy");
assert.ok(html.includes('href="https://apps.apple.com/app/id6788516920"'), "CTA links to App Store");
assert.ok(html.includes('href="https://thetinapp.com/"'), "footer links home");
// Missing params still render (no throw)
assert.doesNotThrow(() => renderCardHTML({ id: "x", name: "", set: "", img: "", origin: "https://thetinapp.com" }));

// --- printed labels carry the copy's printing and condition (LabelPayload v1) ---

const labelled = renderCardHTML({
  id: "base1-4", name: "Charizard", set: "Base Set", img: "",
  printing: "reverseHolo", condition: "NM", origin: "https://thetinapp.com",
});
assert.ok(labelled.includes("Reverse Holo"), "label printing rendered with its display name");
assert.ok(labelled.includes("NM"), "label condition rendered");
assert.ok(labelled.includes('class="copy"'), "copy line present");

// A plain share link carries neither — no empty line, no stray separator.
assert.ok(!html.includes('class="copy"'), "no copy line without p/c");

// An unrecognised value is DROPPED, not escaped-and-shown: the map is the sanitiser, so nothing
// an attacker put in the URL can reach the page as text.
const hostile = renderCardHTML({
  id: "base1-4", name: "Charizard", set: "", img: "",
  printing: "<script>alert(1)</script>", condition: "'; DROP--",
  origin: "https://thetinapp.com",
});
assert.ok(!hostile.includes("<script>"), "unknown printing never emitted raw");
assert.ok(!hostile.includes("alert(1)"), "unknown printing dropped, not merely escaped");
assert.ok(!hostile.includes("DROP--"), "unknown condition dropped, not merely escaped");
assert.ok(!hostile.includes('class="copy"'), "nothing recognised means no copy line at all");

// One half recognised is still worth showing — a label whose printing we know but condition we
// don't should not lose the printing too.
const halfKnown = renderCardHTML({
  id: "base1-4", name: "Charizard", set: "", img: "", printing: "holo", condition: "MINT+",
  origin: "https://thetinapp.com",
});
assert.ok(halfKnown.includes("Holo"), "known half survives");
assert.ok(!halfKnown.includes("MINT+"), "unknown half dropped");

// `v` and `e` are ignored by construction — renderCardHTML is never given them (rules 4 and 5).
assert.doesNotThrow(() => renderCardHTML({
  id: "x", name: "", set: "", img: "", printing: undefined, condition: undefined,
  origin: "https://thetinapp.com",
}));

console.log("card-preview: all assertions passed");
