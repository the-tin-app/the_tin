"""Sweep ORB nfeatures 300..1000 to find the size/accuracy knee on the 64 real photos.
Floor scales with nf (inliers ~ linear in nf). Reports auto-lock%, real wrong-locks
(flagging identical-art ones a twin->chooser mitigation would remove), chooser%, and
estimated pack size (descriptors+keypoints, global_vec dropped)."""
import json, csv, sqlite3, re, cv2, numpy as np, os
from collections import defaultdict

# local mirror of catalog card images (downloaded separately; not in repo)
CACHE=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "images")
con=sqlite3.connect("catalog-v3.sqlite")
CARDS=con.execute("SELECT c.id,c.name,c.number,s.total,c.hp FROM card c JOIN set_info s ON s.id=c.set_id WHERE c.image_base IS NOT NULL").fetchall()
def bn(n):
    n=n.lower()
    for s in [" ex"," vmax"," vstar"," v"," lv.x"]: n=n.replace(s,"")
    return n.replace("mega ","").replace("'","").strip()
BN={c[0]:bn(c[1]) for c in CARDS}
ocr={d["num"]:d.get("text","") for d in json.load(open("ocr_results.json"))}
cond={}
for r in csv.reader(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "test_images", "images.csv"))):
    m=re.match(r"IMG_(\d+)\.png", r[0].strip()) if r else None
    if m: cond[m.group(1)]=r[5].strip()
truth={l.split()[0]:l.split()[1] for l in open("truth.txt")}
truth["1542"]="np-32"; truth["1543"]="np-32"   # engine-verified (Articuno ex hp100)
AMBIG={"1547":{"base1-2","base4-2","dp3-2","pl1-2"},"1552":{"ex1-14","ex12-14"}}
# known identical-art twin sets a twin->chooser mitigation would catch
TWINS=[{"base1-2","base4-2"}]
def is_twin(a,b):
    return any({a,b}<=t for t in TWINS)

def fields(text):
    low=text.lower(); numerators=set(); denom=None
    for a,b in re.findall(r"(\d{1,3})\s*/\s*(\d{1,3})",text):
        numerators.add(a);numerators.add(a.lstrip("0") or a);denom=b.lstrip("0") or b
    for p in re.findall(r"\b([A-Z]{2,4})\s?(\d{1,3})\b",text): numerators.add((p[0]+p[1]).upper())
    hps=set(re.findall(r"HP\s*[:.]?\s*(\d{2,3})",text)+re.findall(r"(\d{2,3})\s*HP",text))
    return numerators,denom,hps,low

def evaluate(nf,floor,margin=1.5):
    O=cv2.ORB_create(nfeatures=nf,scaleFactor=1.2,nlevels=8,edgeThreshold=31,firstLevel=0,WTA_K=2,scoreType=cv2.ORB_HARRIS_SCORE,patchSize=31,fastThreshold=20)
    fc={}
    def fref(cid):
        if cid in fc: return fc[cid]
        p=f"{CACHE}/{cid}.webp";v=None
        if os.path.exists(p):
            b=cv2.imread(p,cv2.IMREAD_COLOR)
            if b is not None:
                g=cv2.cvtColor(cv2.resize(b,(660,920),interpolation=cv2.INTER_AREA),cv2.COLOR_BGR2GRAY)
                k,d=O.detectAndCompute(g,None)
                if d is not None and len(k): v=(np.array([[x.pt[0],x.pt[1]] for x in k],np.float32),d)
        fc[cid]=v;return v
    def fpl(num):
        p=f"plates/{num}.png"
        if not os.path.exists(p): return None
        g=cv2.cvtColor(cv2.imread(p,cv2.IMREAD_COLOR),cv2.COLOR_BGR2GRAY)
        k,d=O.detectAndCompute(g,None)
        return None if d is None or not len(k) else (np.array([[x.pt[0],x.pt[1]] for x in k],np.float32),d)
    def inl(A,B):
        if A is None or B is None: return 0
        (xa,da),(xb,db)=A,B
        if len(xa)<4 or len(xb)<4: return 0
        pa,pb=[],[]
        for m in cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(da,db,k=2):
            if len(m)==2 and m[0].distance<0.75*m[1].distance:
                pa.append(xa[m[0].queryIdx]);pb.append(xb[m[0].trainIdx])
        if len(pa)<4: return len(pa)
        _,mask=cv2.findHomography(np.array(pa),np.array(pb),cv2.RANSAC,5.0)
        return 0 if mask is None else int(mask.sum())
    tally=defaultdict(int); wrongs=[]
    for num in sorted(ocr,key=lambda x:int(x)):
        if num not in truth and num not in AMBIG: continue
        numerators,denom,hps,low=fields(ocr[num])
        pool={}
        for cid,name,cn,total,chp in CARDS:
            nm=len(BN[cid])>=3 and BN[cid] in low
            num_m=cn in numerators or cn.upper() in numerators or cn.lstrip('0') in numerators
            if nm or num_m: pool[cid]=(total,nm,cn)
        if not pool: tally["nonarrow"]+=1; continue
        ids=sorted(pool,key=lambda c:-((pool[c][1])+ (1 if pool[c][2] in numerators else 0)))[:160]
        q=fpl(num)
        sc=sorted(((cid,inl(q,fref(cid)),pool[cid][0],pool[cid][1]) for cid in ids),key=lambda t:-t[1])
        tset=AMBIG.get(num) or {truth.get(num)}
        cons=[s for s in sc if s[3] and (denom is None or not str(denom).isdigit() or s[2]==int(denom) or not any(x[3] and x[2]==int(denom) for x in sc))]
        top=cons[0] if cons else None
        rival=max([s[1] for s in sc if not top or s[0]!=top[0]]+[0])
        auto=bool(top and top[1]>=floor and (rival==0 or top[1]/max(rival,1)>=margin))
        trank=next((i for i,s in enumerate(sc) if s[0] in tset),None)
        if auto:
            if top[0] in tset: tally["ok"]+=1
            else:
                second=sc[1] if len(sc)>1 else None
                twin = second and is_twin(top[0],second[0])
                tally["wrong"]+=1; wrongs.append((num,cond.get(num),top[0],list(tset),twin))
        else:
            tally["chit" if (trank is not None and trank<4) else "cmiss"]+=1
    return tally,wrongs

print(f"{'nf':>5} {'floor':>5} {'size_MB':>7} | {'lock-ok':>7} {'WRONG':>5} {'wrong(-twin)':>12} {'choose-hit':>10} {'choose-miss':>11}")
for nf in [500,650,800,900]:
    floor=max(4,round(0.03*nf))
    t,w=evaluate(nf,floor)
    size=round(0.745*nf/1000*1000)  # ~745MB at nf=1000 (desc+kp, no global_vec)
    n=64
    real_wrong=sum(1 for x in w if not x[4])
    print(f"{nf:>5} {floor:>5} {size:>6}M | {t['ok']:>7} {t['wrong']:>5} {real_wrong:>12} {t['chit']:>10} {t['cmiss']:>11}   {'wrongs='+str([(x[0],x[2],'twin' if x[4] else '') for x in w]) if w else ''}")
