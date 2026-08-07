"""Emit twins.json: identical-art pairs, over two candidate pools.

  (number, lower(name))  — the original pool, ORB-or-dHash as validated 2026-07-08.
  (lower(name), artist)  — WIDER, dHash required (see `twins.is_twin`).

⚠️ The second pool exists because of a specific wrong lock. The only wrong answer in the 415-cell
measured fixture set was `base1-2`/`base4-2` Blastoise answered as `cel25cc-CC001` — a third
identical-art reprint numbered `CC001`, which a pool keyed on the collector number can never place
beside the other two. (Wrong locks later seen on a real device were plainly wrong cards, not paired
art, so this pool does not address those.) All three share Ken Sugimori's illustration, so the artist is the link.
Measured on catalog v35: (number, name) alone is 1,405 candidate pairs, adding (name, artist) makes
9,727, and pooling by name alone would be 167,433 — the artist is what makes widening affordable.

⚠️ **The output must be committed to `functions/data/card-twins.json`, not left in `.fp-output/`.**
That directory is gitignored AND outside the pipeline's Docker build context, which is why every
published catalog had `card_twin` at 0 rows for months while the code to write it was already there.

Usage: python scripts/build_twins.py --catalog PATH/catalog.sqlite \
    --images .cache/images --out .fp-output/twins.json"""
import argparse, itertools, json, os, sqlite3, cv2
from fpcore import build, twins

def gray(images_dir, cid):
    p = os.path.join(images_dir, f"{cid}.webp")
    if not os.path.exists(p): return None
    b = cv2.imread(p, cv2.IMREAD_COLOR)
    if b is None: return None
    return cv2.cvtColor(cv2.resize(b, (660, 920), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--images", default=os.path.join(os.path.dirname(__file__), "..", ".cache", "images"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", ".fp-output", "twins.json"))
    args = ap.parse_args()
    con = sqlite3.connect(args.catalog)
    by_number_name, by_name_artist = {}, {}
    for cid, num, name, artist in con.execute(
        f"SELECT id, number, lower(name), artist FROM card WHERE {build.FINGERPRINTABLE_WHERE}"):
        by_number_name.setdefault((num, name), []).append(cid)
        if artist:
            by_name_artist.setdefault((name, artist), []).append(cid)
    con.close()

    # (pair -> whether dHash is required). A pair reachable from the ORIGINAL pool keeps the original,
    # validated rule even if the wider pool also proposes it.
    candidates = {}
    for ids in by_name_artist.values():
        if len(ids) < 2: continue
        for a, b in itertools.combinations(sorted(ids), 2):
            candidates[(a, b)] = True
    for ids in by_number_name.values():
        if len(ids) < 2: continue
        for a, b in itertools.combinations(sorted(ids), 2):
            candidates[(a, b)] = False
    print(f"{len(candidates)} candidate pairs")

    grays, out = {}, []
    def load(cid):
        if cid not in grays: grays[cid] = gray(args.images, cid)
        return grays[cid]

    for (a, b), require_dhash in sorted(candidates.items()):
        ga, gb = load(a), load(b)
        if ga is None or gb is None: continue
        if twins.is_twin(ga, gb, require_dhash=require_dhash):
            out.append([a, b])
    out.sort()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    # One pair per line, sorted, so a regeneration is a reviewable diff rather than a reshuffle.
    with open(args.out, "w") as f:
        f.write("[\n" + ",\n".join(f'  ["{a}", "{b}"]' for a, b in out) + "\n]\n")
    print(f"wrote {len(out)} twin pairs to {args.out}")
    print("⚠️ copy this to functions/data/card-twins.json — .fp-output/ is gitignored and outside "
          "the pipeline's Docker build context, which is why card_twin was 0 rows for months")

if __name__ == "__main__":
    main()
