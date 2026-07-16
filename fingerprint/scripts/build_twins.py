"""Emit twins.json: identical-art pairs within each (number, lower(name)) pool.
Usage: python scripts/build_twins.py --catalog PATH/catalog.sqlite \
    --images .cache/images --out .fp-output/twins.json"""
import argparse, json, os, sqlite3, cv2
from fpcore import twins

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
    pools = {}
    for cid, num, name in con.execute(
        "SELECT id, number, lower(name) FROM card WHERE image_base IS NOT NULL"):
        pools.setdefault((num, name), []).append(cid)
    con.close()
    out = []
    for ids in pools.values():
        if len(ids) < 2: continue
        grays = {c: gray(args.images, c) for c in ids}
        for i, a in enumerate(ids):
            for b in ids[i+1:]:
                if grays[a] is None or grays[b] is None: continue
                if twins.is_twin(grays[a], grays[b]):
                    out.append(sorted([a, b]))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f: json.dump(out, f)
    print(f"wrote {len(out)} twin pairs to {args.out}")

if __name__ == "__main__":
    main()
