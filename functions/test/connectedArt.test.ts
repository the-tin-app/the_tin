import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { loadScenes } from "../src/pipeline/connectedArt";

describe("loadScenes", () => {
  it("loads the seed dataset and every scene has ≥2 ordered cards", () => {
    const raw = JSON.parse(readFileSync(`${__dirname}/../data/connected-art.json`, "utf8"));
    const scenes = loadScenes(raw);
    expect(scenes.length).toBeGreaterThanOrEqual(10);
    for (const s of scenes) {
      expect(s.cardIds.length).toBeGreaterThanOrEqual(2);
      expect(s.sceneId).toMatch(/^[a-z0-9.-]+$/); // set ids can contain a dot (e.g. sv03.5)
      expect(s.title.length).toBeGreaterThan(0);
    }
  });

  it("rejects duplicate sceneIds", () => {
    const bad = [{ sceneId: "x", title: "A", cardIds: ["a-1", "a-2"] }, { sceneId: "x", title: "B", cardIds: ["b-1", "b-2"] }];
    expect(() => loadScenes(bad)).toThrow(/duplicate/i);
  });

  it("rejects scenes with fewer than 2 cards", () => {
    expect(() => loadScenes([{ sceneId: "y", title: "Solo", cardIds: ["a-1"] }])).toThrow(/at least 2/i);
  });

  it("rejects a non-array root", () => {
    expect(() => loadScenes({ sceneId: "x", title: "A", cardIds: ["a-1", "a-2"] })).toThrow(/must be an array/);
    expect(() => loadScenes("not an array")).toThrow(/must be an array/);
    expect(() => loadScenes(null)).toThrow(/must be an array/);
  });

  it("rejects elements missing sceneId/title/cardIds, including null/non-object elements", () => {
    expect(() => loadScenes([{ title: "A", cardIds: ["a-1", "a-2"] }])).toThrow(/missing/);
    expect(() => loadScenes([{ sceneId: "x", cardIds: ["a-1", "a-2"] }])).toThrow(/missing/);
    expect(() => loadScenes([{ sceneId: "x", title: "A" }])).toThrow(/missing/);
    expect(() => loadScenes([null])).toThrow(/missing/);
    expect(() => loadScenes(["not-an-object"])).toThrow(/missing/);
  });
});
