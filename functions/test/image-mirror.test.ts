import { describe, it, expect, vi } from "vitest";
import { mirrorImage, ImageStore } from "../src/pipeline/image-mirror";

function store(existing = false): ImageStore & { saved: any[] } {
  const saved: any[] = [];
  return {
    saved,
    exists: async () => existing,
    save: async (p, d, c) => { saved.push({ p, len: d.length, c }); },
    downloadUrl: (p) => `https://bucket/${p}`,
  };
}

it("skips download+upload when the object already exists", async () => {
  const s = store(true);
  const fetchFn = vi.fn();
  const url = await mirrorImage("mep-1", "http://src/x.jpg", s, fetchFn as any);
  expect(url).toBe("https://bucket/card-images/mep-1.jpg");
  expect(fetchFn).not.toHaveBeenCalled();
  expect(s.saved).toHaveLength(0);
});

it("downloads and uploads when absent", async () => {
  const s = store(false);
  const fetchFn = vi.fn(async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer })) as any;
  const url = await mirrorImage("mep-1", "http://src/x.jpg", s, fetchFn);
  expect(url).toBe("https://bucket/card-images/mep-1.jpg");
  expect(s.saved[0]).toMatchObject({ p: "card-images/mep-1.jpg", len: 3, c: "image/jpeg" });
});

it("throws on a failed download", async () => {
  const s = store(false);
  const fetchFn = vi.fn(async () => ({ ok: false, status: 404 })) as any;
  await expect(mirrorImage("mep-1", "http://src/x.jpg", s, fetchFn)).rejects.toThrow(/404/);
});
