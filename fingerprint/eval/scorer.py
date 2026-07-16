"""Faithful eval of the INTENDED pipeline: soft-narrow by name+HP+number (any field
that OCRs), visual-confirm with the exact prod matcher, then a CONSISTENCY gate that
only confident-locks when the winner agrees with the recovered OCR fields (incl. the
denominator, which breaks identical-art ties). Corrected metrics: only a confident
WRONG lock is a failure; a top-4 chooser is acceptable."""
import json, csv, sqlite3, re, cv2, numpy as np, os
from collections import defaultdict

# local mirror of catalog card images (downloaded separately; not in repo)
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "images")
NF, FLOOR, MARGIN = 1000, 30, 1.5
con = sqlite3.connect("catalog-v3.sqlite")
CARDS = con.execute("SELECT c.id,c.name,c.number,s.total,c.hp FROM card c JOIN set_info s ON s.id=c.set_id WHERE c.image_base IS NOT NULL").fetchall()
def base_name(n):
    n=n.lower()
    for s in [" ex"," vmax"," vstar"," v"," lv.x"]: n=n.replace(s,"")
    return n.replace("mega ","").replace("'","").strip()
BASENAME={c[0]:base_name(c[1]) for c in CARDS}

ocr={d["num"]:d.get("text","") for d in json.load(open("ocr_results.json"))}
cond={}
for r in csv.reader(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "test_images", "images.csv"))):
    m = re.match(r"IMG_(\d+)\.png", r[0].strip()) if r else None
    if m: cond[m.group(1)] = r[5].strip()
truth={l.split()[0]:l.split()[1] for l in open("truth.txt")}
AMBIG={"1542":{"bw11-32","sm9-32","sv09-032"},"1543":{"bw11-32","sm9-32","sv09-032"},
       "1547":{"base1-2","base4-2","dp3-2","pl1-2"},"1552":{"ex1-14","ex12-14"}}

O=cv2.ORB_create(nfeatures=NF,scaleFactor=1.2,nlevels=8,edgeThreshold=31,firstLevel=0,WTA_K=2,scoreType=cv2.ORB_HARRIS_SCORE,patchSize=31,fastThreshold=20)
_f={}
def fref(cid):
    if cid in _f: return _f[cid]
    p=f"{CACHE}/{cid}.webp";v=None
    if os.path.exists(p):
        b=cv2.imread(p,cv2.IMREAD_COLOR)
        if b is not None:
            g=cv2.cvtColor(cv2.resize(b,(660,920),interpolation=cv2.INTER_AREA),cv2.COLOR_BGR2GRAY)
            k,d=O.detectAndCompute(g,None)
            if d is not None and len(k):v=(np.array([[x.pt[0],x.pt[1]] for x in k],np.float32),d)
    _f[cid]=v;return v
def fplate(num):
    p=f"plates/{num}.png"
    if not os.path.exists(p):return None
    g=cv2.cvtColor(cv2.imread(p,cv2.IMREAD_COLOR),cv2.COLOR_BGR2GRAY)
    k,d=O.detectAndCompute(g,None)
    return None if d is None or not len(k) else (np.array([[x.pt[0],x.pt[1]] for x in k],np.float32),d)
def inl(A,B):
    if A is None or B is None:return 0
    (xa,da),(xb,db)=A,B
    if len(xa)<4 or len(xb)<4:return 0
    knn=cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(da,db,k=2)
    pa,pb=[],[]
    for m in knn:
        if len(m)==2 and m[0].distance<0.75*m[1].distance:
            pa.append(xa[m[0].queryIdx]);pb.append(xb[m[0].trainIdx])
    if len(pa)<4:return len(pa)
    _,mask=cv2.findHomography(np.array(pa),np.array(pb),cv2.RANSAC,5.0)
    return 0 if mask is None else int(mask.sum())

def fields(text):
    low=text.lower()
    nums=re.findall(r"(\d{1,3})\s*/\s*(\d{1,3})",text)
    numerators=set();denom=None
    for a,b in nums:
        numerators.add(a);numerators.add(a.lstrip("0") or a);denom=b.lstrip("0") or b
    for p in re.findall(r"\b([A-Z]{2,4})\s?(\d{1,3})\b",text):
        numerators.add((p[0]+p[1]).upper())
    hps=set(re.findall(r"HP\s*[:.]?\s*(\d{2,3})",text)+re.findall(r"(\d{2,3})\s*HP",text))
    return numerators,denom,hps,low

rows=[]
for num in sorted(ocr,key=lambda x:int(x)):
    if num not in truth and num not in AMBIG: continue
    text=ocr[num]; numerators,denom,hps,low=fields(text)
    got_num=bool(numerators); got_name=False
    # soft narrow: any card whose name is in the text, OR number matches, OR hp matches (as a set)
    pool={}
    for cid,name,cn,total,chp in CARDS:
        bn=BASENAME[cid]
        nm = len(bn)>=3 and bn in low
        num_m = cn in numerators or cn.upper() in numerators or (cn.lstrip('0') in numerators)
        hp_m = hps and str(chp) in hps
        if nm or num_m:
            agree=(1 if nm else 0)+(1 if num_m else 0)+(1 if hp_m else 0)
            denom_ok = (denom is not None and str(total)==denom)
            pool[cid]=(name,cn,total,chp,nm,num_m,hp_m,denom_ok,agree)
            if nm: got_name=True
    if not pool:
        rows.append(dict(num=num,cond=cond.get(num),cls="NO-NARROW",got_num=got_num,got_name=False,
                         top1=None,truth=list(AMBIG.get(num) or {truth.get(num)}),trank=None,pool=0));continue
    # prioritize by agreement to cap pool for the visual step
    ids=sorted(pool,key=lambda c:-pool[c][8])[:160]
    q=fplate(num)
    sc=[(cid,inl(q,fref(cid)))+pool[cid] for cid in ids]  # (cid,inliers,name,cn,total,chp,nm,num_m,hp_m,denom_ok,agree)
    sc.sort(key=lambda t:-t[1])
    tset=AMBIG.get(num) or {truth.get(num)}
    # consistency gate: a card may confident-lock only if name agrees AND (no denom OR denom==total)
    def consistent(s): return s[6] and (denom is None or s[4]==int(denom) if str(denom).isdigit() else s[6])
    cons=[s for s in sc if s[6] and (denom is None or (str(denom).isdigit() and s[4]==int(denom)) or not any(str(x[4])==denom for x in sc if x[6]))]
    top=cons[0] if cons else None
    # margin computed over ALL candidates (a strong inconsistent rival still blocks the lock)
    second=sc[1][1] if len(sc)>1 and sc[1][0]!=(top[0] if top else None) else (sc[0][1] if sc and top and sc[0][0]!=top[0] else 0)
    rival=max([s[1] for s in sc if not top or s[0]!=top[0]]+[0])
    auto=bool(top and top[1]>=FLOOR and (rival==0 or top[1]/max(rival,1)>=MARGIN))
    top4=[s[0] for s in sc[:4]]
    trank=next((i for i,s in enumerate(sc) if s[0] in tset),None)
    if auto: cls="AUTOLOCK-OK" if top[0] in tset else "AUTOLOCK-WRONG"
    else: cls="CHOOSER-HIT" if (trank is not None and trank<4) else "CHOOSER-MISS"
    rows.append(dict(num=num,cond=cond.get(num),cls=cls,got_num=got_num,got_name=got_name,
        top1=(sc[0][0],sc[0][1]),lock=(top[0],top[1]) if top else None,truth=list(tset),trank=trank,pool=len(pool)))

by=defaultdict(lambda:defaultdict(int))
for r in rows:
    for k in ("ALL",r["cond"]):
        by[k][r["cls"]]+=1;by[k]["_n"]+=1
        by[k]["_num"]+=r["got_num"];by[k]["_name"]+=r["got_name"]
order=["AUTOLOCK-OK","AUTOLOCK-WRONG","CHOOSER-HIT","CHOOSER-MISS","NO-NARROW"]
print(f"NF={NF} FLOOR={FLOOR} MARGIN={MARGIN}\n")
print(f"{'cond':<12}{'n':>3} {'num%':>5} {'name%':>6} | {'LOCK-ok':>8}{'LOCK-WRONG':>11}{'CHOOSE-hit':>11}{'CHOOSE-miss':>12}{'no-narrow':>10}")
for c in ["ALL","plain","raw","sleeve","perfect","top-sleeve","case-sleeve"]:
    if c not in by:continue
    d=by[c];n=d["_n"]
    print(f"{c:<12}{n:>3} {100*d['_num']//n:>4}% {100*d['_name']//n:>5}% | {d['AUTOLOCK-OK']:>8}{d['AUTOLOCK-WRONG']:>11}{d['CHOOSER-HIT']:>11}{d['CHOOSER-MISS']:>12}{d['NO-NARROW']:>10}")
print("\n--- WRONG auto-locks (ONLY real failures) ---")
for r in rows:
    if r["cls"]=="AUTOLOCK-WRONG": print(f"  {r['num']} {r['cond']:<11} locked={r['lock']} truth={r['truth']} rank={r['trank']}")
print("\n--- CHOOSER-MISS / NO-NARROW (recoverable; not wrong-locks) ---")
for r in rows:
    if r["cls"] in ("CHOOSER-MISS","NO-NARROW"): print(f"  {r['num']} {r['cond']:<11} {r['cls']:<12} top1={r['top1']} truth={r['truth']} rank={r['trank']} numOCR={r['got_num']} nameOCR={r['got_name']} pool={r['pool']}")
