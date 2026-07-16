"""Resolve each labeled photo to a true card_id from the catalog via
name + numerator (+ denominator/total + HP). Flag unresolved / ambiguous."""
import csv, sqlite3, re, os, glob

# built catalog artifact (produced by the catalog pipeline; not in repo)
CAT = "catalog-v3.sqlite"
IMGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "test_images")
con = sqlite3.connect(CAT)

def norm(s): return (s or "").strip()
def numvariants(n):
    n = norm(n)
    out = {n, n.lstrip("0") or n, n.upper(), n.lower()}
    if n.lstrip("0"): out.add(n.lstrip("0"))
    return {x for x in out if x}

rows = []
with open(f"{IMGDIR}/images.csv") as f:
    for r in csv.reader(f):
        m = re.match(r"IMG_(\d+)\.png", r[0].strip()) if r else None
        if not m: continue
        r = [norm(x) for x in r]
        r[0] = m.group(1)
        rows.append(r)

# which image files exist
files = {re.search(r"IMG_(\d+)", os.path.basename(p)).group(1): os.path.basename(p)
         for p in glob.glob(f"{IMGDIR}/IMG_*.png")}
labeled_nums = {r[0] for r in rows}
print(f"CSV rows: {len(rows)} | image files: {len(files)}")
missing_label = sorted(set(files) - labeled_nums)
missing_file = sorted(labeled_nums - set(files))
if missing_label: print(f"IMAGES WITHOUT A CSV ROW: {[files[n] for n in missing_label]}")
if missing_file: print(f"CSV ROWS WITHOUT AN IMAGE: {missing_file}")

def resolve(name, hp, num, denom):
    nvs = numvariants(num)
    ph = "(" + ",".join("?"*len(nvs)) + ")"
    q = (f"SELECT c.id, s.total, c.hp, s.name FROM card c JOIN set_info s ON s.id=c.set_id "
         f"WHERE lower(c.name)=lower(?) AND c.number IN {ph}")
    cands = con.execute(q, [name, *nvs]).fetchall()
    if not cands:  # fallback: name prefix (handle misspellings/trainers) + number
        cands = con.execute(
            f"SELECT c.id, s.total, c.hp, s.name FROM card c JOIN set_info s ON s.id=c.set_id "
            f"WHERE c.number IN {ph} AND lower(c.name) LIKE lower(?)", [*nvs, name[:5]+"%"]).fetchall()
    if not cands: return "NONE", []
    # prefer denominator == set total, then HP match
    def score(row):
        _id, total, chp, sname = row
        s = 0
        if denom not in ("", "null", None) and str(total) == denom.lstrip("0"): s += 2
        if hp not in ("", "null", None) and str(chp) == hp: s += 1
        return s
    cands.sort(key=score, reverse=True)
    best = score(cands[0])
    top = [c for c in cands if score(c) == best]
    if len(top) == 1: return top[0][0], top
    return "AMBIG", top

unresolved = []
print(f"\n{'img':>5} {'name':<12} {'num':>6}/{'den':<5} {'hp':>4} {'cond':<11} -> resolved")
for r in rows:
    img, name, hp, num, den, cond = (r + [""]*6)[:6]
    cid, cands = resolve(name, hp, num, den)
    tag = cid if cid not in ("NONE","AMBIG") else f"** {cid} **"
    extra = ""
    if cid == "AMBIG": extra = "  [" + ", ".join(f"{c[0]}(tot{c[1]},hp{c[2]})" for c in cands[:6]) + "]"
    if cid == "NONE": unresolved.append(img)
    if cid == "AMBIG": unresolved.append(img)
    print(f"{img:>5} {name:<12} {num:>6}/{den:<5} {hp:>4} {cond:<11} -> {tag}{extra}")

print(f"\nUNRESOLVED/AMBIGUOUS rows: {unresolved}")
# condition histogram
from collections import Counter
print("conditions:", dict(Counter(r[5] for r in rows)))
