export interface ImageStore {
  exists(path: string): Promise<boolean>;
  save(path: string, data: Buffer, contentType: string): Promise<void>;
  /** URL the app fetches the object from. For PPT-sourced images this is an auth-gated Firebase
   *  download endpoint (App Check + auth required) — NOT a public URL. See firebaseImageStore. */
  downloadUrl(path: string): string;
}

/** Mirror a PPT/TCGplayer image into our bucket. Idempotent: if the object already exists we
 *  return its URL without re-downloading (so re-runs are cheap and don't refetch every image). */
export async function mirrorImage(cardId: string, sourceUrl: string, store: ImageStore, fetchFn: typeof fetch = fetch): Promise<string> {
  const path = `card-images/${cardId}.jpg`;
  if (await store.exists(path)) return store.downloadUrl(path);
  const res = await fetchFn(sourceUrl);
  if (!res.ok) throw new Error(`image download ${res.status} for ${sourceUrl}`);
  const buf = Buffer.from(await res.arrayBuffer());
  await store.save(path, buf, "image/jpeg");
  return store.downloadUrl(path);
}
