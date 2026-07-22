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
// Install CTA copy + link home
assert.ok(html.includes("Coming to the App Store"), "install CTA copy");
assert.ok(html.includes('href="https://thetinapp.com/"'), "CTA links home");
// Missing params still render (no throw)
assert.doesNotThrow(() => renderCardHTML({ id: "x", name: "", set: "", img: "", origin: "https://thetinapp.com" }));

console.log("card-preview: all assertions passed");
