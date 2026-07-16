export interface ArtScene { sceneId: string; title: string; cardIds: string[]; kind?: "combined" | "narrative" }

export function loadScenes(json: unknown): ArtScene[] {
  if (!Array.isArray(json)) throw new Error("connected-art: root must be an array");
  const seen = new Set<string>();
  return json.map((s: any, i: number) => {
    if (typeof s !== "object" || s === null || typeof s.sceneId !== "string" || typeof s.title !== "string" || !Array.isArray(s.cardIds))
      throw new Error(`connected-art[${i}]: missing sceneId/title/cardIds`);
    if (seen.has(s.sceneId)) throw new Error(`connected-art: duplicate sceneId ${s.sceneId}`);
    seen.add(s.sceneId);
    if (s.cardIds.length < 2) throw new Error(`connected-art[${s.sceneId}]: needs at least 2 cards`);
    const kind: ArtScene["kind"] = s.kind === "narrative" ? "narrative" : s.kind === "combined" ? "combined" : undefined;
    return { sceneId: s.sceneId, title: s.title, cardIds: s.cardIds.map(String), kind };
  });
}
