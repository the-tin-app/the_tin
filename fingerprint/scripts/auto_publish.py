"""Automated scanner-pack publish: detect new cards -> incremental build -> validate -> ship.

Replaces the manual build + rsync in scripts/README.md §2-4. Designed to run daily from cron
inside the fp-pipeline container (see fingerprint/pipeline/); the heavy path only runs when
the catalog has cards the live pack lacks.

  Stage 0  detect     catalog cards (casual tier) without a row in the live pack
  Stage 1  build      seed from the live pack, fingerprint only the missing cards
  Stage 2  stage      split into 50 MiB parts + manifest under <work>/stage
  Stage 3  validate   every gate in fpcore/packcheck.py, incl. no card lost vs the live pack
  Stage 4  ship       NAS parts -> verify on the NAS -> R2 -> NAS manifest LAST -> read back both
  Stage 5  prune      old versions, 24 h after the new one went live

A failed run never changes what clients are served. `--dry-run` runs stages 0-3 only.

Required layout: --data-root is the catalog-server data dir (the NAS mount): it holds
`catalog/` and `fingerprint/`. Manifest paths are relative to it (`fingerprint/parts/...`).
"""
import argparse
import fcntl
import gzip
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import urllib.request
from datetime import datetime, timedelta
from fpcore import autopublish as ap, build, codebook as cb, packcheck, publish

HERE = os.path.dirname(os.path.abspath(__file__))
R2_BUCKET = "tin-artifacts"


def _load_script(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def notify(tag: str, message: str):
    """Print always; post to NOTIFY_URL when configured (kept out of the public repo, like the
    catalog pipeline's notify hook). Never raises: alerting must not mask the real outcome."""
    print(f"[fp-auto] NOTIFY {tag}: {message}", flush=True)
    url, key = os.environ.get("NOTIFY_URL"), os.environ.get("NOTIFY_API_KEY")
    if not (url and key):
        return
    body = json.dumps({"service": "fp-pipeline", "tag": tag, "message": message,
                       "recipient": "tomas"}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:  # noqa: BLE001
        print(f"[fp-auto] WARN notify failed: {e}", flush=True)


# --- R2 (S3-compatible API) -------------------------------------------------------------

_r2_client = None


def r2():
    """boto3 S3 client for the R2 bucket. Credentials: R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY when
    set, else derived from CLOUDFLARE_API_TOKEN the way Cloudflare documents for R2 API tokens
    (key id = the token's id, secret = sha256 of the token value). Bucket-scoped
    "Object Read & Write" tokens work; wrangler's REST object API would need a broader token."""
    global _r2_client
    if _r2_client is None:
        import boto3
        from botocore.config import Config
        acct = os.environ["CLOUDFLARE_ACCOUNT_ID"]
        kid, secret = os.environ.get("R2_ACCESS_KEY_ID"), os.environ.get("R2_SECRET_ACCESS_KEY")
        if not (kid and secret):
            tok = os.environ["CLOUDFLARE_API_TOKEN"]
            req = urllib.request.Request(
                f"https://api.cloudflare.com/client/v4/accounts/{acct}/tokens/verify",
                headers={"Authorization": f"Bearer {tok}"})
            kid = json.load(urllib.request.urlopen(req, timeout=20))["result"]["id"]
            secret = hashlib.sha256(tok.encode()).hexdigest()
        _r2_client = boto3.client(
            "s3", endpoint_url=f"https://{acct}.r2.cloudflarestorage.com", region_name="auto",
            aws_access_key_id=kid, aws_secret_access_key=secret,
            config=Config(signature_version="s3v4", retries={"max_attempts": 5}))
    return _r2_client


def r2_get_manifest():
    """The manifest R2 serves, or (None, None) when absent/unreadable. Returns (dict, raw_bytes)."""
    try:
        raw = r2().get_object(Bucket=R2_BUCKET, Key="fingerprint/parts/manifest.json")["Body"].read()
        return json.loads(raw), raw
    except Exception as e:  # noqa: BLE001 — unreadable is reported by the caller, never fatal here
        print(f"[fp-auto] WARN cannot read R2 manifest: {type(e).__name__}: {e}", flush=True)
        return None, None


def r2_put(path: str, key: str):
    try:
        r2().upload_file(path, R2_BUCKET, key)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"R2 put {key} failed: {e}") from e


def r2_delete(key: str):
    r2().delete_object(Bucket=R2_BUCKET, Key=key)


def r2_part_versions() -> dict:
    """{version: [keys]} for every part object in the bucket (the S3 API can list; wrangler
    could not, which is why prune used to rely on remembered state)."""
    out = {}
    pager = r2().get_paginator("list_objects_v2")
    for page in pager.paginate(Bucket=R2_BUCKET, Prefix="fingerprint/parts/"):
        for o in page.get("Contents", []):
            m = ap._PART_VER_RE.search(o["Key"])
            if m:
                out.setdefault(int(m.group(1)), []).append(o["Key"])
    return out


# --- helpers ------------------------------------------------------------------------------

def nas_paths(data_root):
    fp = os.path.join(data_root, "fingerprint")
    return fp, os.path.join(fp, "parts"), os.path.join(fp, "parts", "manifest.json")


def latest_casual_catalog(catalog_dir):
    best = None
    for n in os.listdir(catalog_dir):
        if n.startswith("casual-v") and n.endswith(".sqlite.gz"):
            v = int(n[len("casual-v"):-len(".sqlite.gz")])
            if best is None or v > best[0]:
                best = (v, os.path.join(catalog_dir, n))
    if best is None:
        raise SystemExit(f"no casual-v*.sqlite.gz under {catalog_dir}")
    return best


def gunzip_to(src, dest):
    with gzip.open(src, "rb") as i, open(dest, "wb") as o:
        shutil.copyfileobj(i, o, 1 << 20)


def atomic_copy(src, dest):
    tmp = os.path.join(os.path.dirname(dest), "." + os.path.basename(dest) + ".tmp")
    shutil.copyfile(src, tmp)
    with open(tmp, "rb") as f:
        os.fsync(f.fileno())
    os.replace(tmp, dest)


def write_manifest_atomic(path, raw: bytes):
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# --- stages -------------------------------------------------------------------------------

def stage_and_validate(args, new_db, live_db, version, live_size, codebook_hash):
    """Stages 2-3. Returns (manifest, stage_dir) or raises RuntimeError naming the failed gate."""
    stage = os.path.join(args.work, "stage")
    shutil.rmtree(stage, ignore_errors=True)
    built_at = ap.now_utc().isoformat().replace("+00:00", "Z")
    whole, total, parts = publish.split_into_parts(new_db, stage, version)
    manifest = publish.make_parts_manifest(version, codebook_hash, built_at, whole, total, parts)
    mpath = os.path.join(stage, publish.parts_dir_name(), "manifest.json")
    with open(mpath, "w") as f:
        json.dump(manifest, f)
    rep = packcheck.validate(stage, mpath, os.path.join(args.work, "scratch"),
                             expected_codebook_hash=codebook_hash,
                             live_db_path=live_db, live_size=live_size)
    print(f"[fp-auto] staged v{version}: {total} B, {len(parts)} parts; validate -> "
          f"{'OK' if rep.ok else 'FAIL'} {rep.info}", flush=True)
    if not rep.ok:
        raise RuntimeError("validation failed: " + "; ".join(rep.failures))
    return manifest, stage


def ship(args, manifest, stage, state):
    """Stage 4. Order matters: payload before any manifest; NAS manifest flips LAST."""
    version = manifest["version"]
    _, nas_parts, nas_manifest = nas_paths(args.data_root)
    old_nas_raw = open(nas_manifest, "rb").read() if os.path.exists(nas_manifest) else None
    _, old_r2_raw = r2_get_manifest()
    r2_flipped = nas_flipped = False
    try:
        # 1. NAS parts (atomic per file), then re-validate the files AS THEY SIT on the NAS.
        for p in manifest["parts"]:
            atomic_copy(os.path.join(stage, p["path"]),
                        os.path.join(args.data_root, p["path"]))
        rep = packcheck.validate(args.data_root, os.path.join(stage, publish.parts_dir_name(),
                                 "manifest.json"), os.path.join(args.work, "scratch"),
                                 expected_codebook_hash=manifest["codebookHash"])
        if not rep.ok:
            raise RuntimeError("NAS copy failed validation: " + "; ".join(rep.failures))
        # 2. R2: parts, then manifest, then read back.
        for p in manifest["parts"]:
            r2_put(os.path.join(stage, p["path"]), p["path"])
        r2_put(os.path.join(stage, publish.parts_dir_name(), "manifest.json"),
               "fingerprint/parts/manifest.json")
        r2_flipped = True
        served, _ = r2_get_manifest()
        if not served or served.get("version") != version or served.get("sha256") != manifest["sha256"]:
            raise RuntimeError(f"R2 does not serve v{version} after upload (serves "
                               f"{served and served.get('version')})")
        # 3. NAS manifest, last.
        raw = json.dumps(manifest).encode()
        write_manifest_atomic(nas_manifest, raw)
        nas_flipped = True
        got = json.loads(open(nas_manifest, "rb").read())
        if got.get("version") != version or got.get("sha256") != manifest["sha256"]:
            raise RuntimeError("NAS manifest read-back mismatch")
    except Exception:
        # Roll the origins back to what they served before, then re-raise for the alert.
        if nas_flipped and old_nas_raw:
            write_manifest_atomic(nas_manifest, old_nas_raw)
        if r2_flipped and old_r2_raw:
            tmp = os.path.join(args.work, "r2-rollback-manifest.json")
            open(tmp, "wb").write(old_r2_raw)
            try:
                r2_put(tmp, "fingerprint/parts/manifest.json")
            except RuntimeError as e:
                notify("Error", f"ROLLBACK of R2 manifest FAILED: {e}. R2 may serve v{version}.")
        raise


def prune(args, state):
    """Stage 5: only once the newest publish has been live >= 24 h, and never anything either
    origin's manifest references."""
    pubs = state["published"]
    if not pubs or ap.now_utc() - datetime.fromisoformat(pubs[-1]["at"]) < timedelta(hours=24):
        return
    _, nas_parts, nas_manifest = nas_paths(args.data_root)
    nas_v = json.load(open(nas_manifest))["version"]
    r2m, _ = r2_get_manifest()
    referenced = {nas_v} | ({r2m["version"]} if r2m else set())
    prev = pubs[-2]["version"] if len(pubs) > 1 else None
    for v in ap.prunable_versions(ap.part_versions(nas_parts), referenced, prev):
        for n in sorted(os.listdir(nas_parts)):
            if n.startswith(f"fingerprints-v{v}.part"):
                os.remove(os.path.join(nas_parts, n))
        print(f"[fp-auto] pruned v{v} from the NAS", flush=True)
    try:
        r2_versions = r2_part_versions()
    except Exception as e:  # noqa: BLE001
        print(f"[fp-auto] WARN cannot list R2, skipping R2 prune: {e}", flush=True)
        return
    for v in ap.prunable_versions(set(r2_versions), referenced, prev):
        for key in r2_versions[v]:
            r2_delete(key)
        print(f"[fp-auto] pruned v{v} from R2 ({len(r2_versions[v])} objects)", flush=True)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--data-root", default="/data")
    a.add_argument("--work", default="/work")
    a.add_argument("--state", default="/state/state.json")
    a.add_argument("--codebook", default=os.path.join(HERE, "..", "fpcore", "codebook.bin"))
    a.add_argument("--cache-dir", default=os.environ.get("FP_CACHE_DIR"))
    a.add_argument("--dry-run", action="store_true", help="stages 0-3 only; never touch NAS/R2")
    a.add_argument("--force", action="store_true", help="skip the debounce")
    a.add_argument("--check-only", action="store_true",
                   help="validate the live pack and compare NAS vs R2; build nothing")
    a.add_argument("--min-interval-days", type=float, default=1.0,
                   help="never publish twice within this window")
    args = a.parse_args()
    os.makedirs(args.work, exist_ok=True)

    lock = open(os.path.join(args.work, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("[fp-auto] another run holds the lock; exiting", flush=True)
        return 0

    now = ap.now_utc()
    state = ap.load_state(args.state)
    book = cb.Codebook.load(args.codebook)
    codebook_hash = book.sha256_hex()
    _, nas_parts, nas_manifest = nas_paths(args.data_root)

    # --- live pack must be sound before we build on it or compare against it ----------------
    live_rep = packcheck.validate(args.data_root, nas_manifest, os.path.join(args.work, "scratch"),
                                  expected_codebook_hash=codebook_hash)
    if not live_rep.ok:
        notify("Error", "LIVE scanner pack on the NAS fails validation: "
                        + "; ".join(live_rep.failures)[:600])
        return 2
    nas_m = json.load(open(nas_manifest))
    r2_m, _ = r2_get_manifest()
    if r2_m is None or r2_m.get("version") != nas_m["version"] or r2_m.get("sha256") != nas_m["sha256"]:
        last = state.get("drift_alerted_at")
        if not last or now - datetime.fromisoformat(last) >= timedelta(days=3):
            what = ("R2 could not be read (token/network?)" if r2_m is None else
                    f"R2 serves v{r2_m.get('version')}")
            notify("Warning", f"scanner pack origins differ or are unverifiable: NAS serves "
                              f"v{nas_m['version']}; {what}")
            state["drift_alerted_at"] = now.isoformat()
    else:
        state.pop("drift_alerted_at", None)
    if args.check_only:
        ap.save_state(args.state, state)
        print(f"[fp-auto] check-only: live pack v{nas_m['version']} valid; "
              f"R2 v{r2_m and r2_m.get('version')}", flush=True)
        return 0

    # --- stage 0: detect --------------------------------------------------------------------
    live_db = os.path.join(args.work, "live.sqlite")
    packcheck.assemble(args.data_root, nas_m, live_db)
    ok, why = ap.pack_meta_matches(live_db, codebook_hash)
    if not ok:
        notify("Error", f"scanner pack auto-build refused: {why}. A full manual rebuild is needed.")
        return 3
    cat_v, cat_gz = latest_casual_catalog(os.path.join(args.data_root, "catalog"))
    catalog = os.path.join(args.work, "catalog.sqlite")
    gunzip_to(cat_gz, catalog)
    missing = ap.missing_card_ids(catalog, live_db)
    state["ledger"] = ap.update_ledger(state["ledger"], missing, now)
    stuck = ap.stuck_cards(state["ledger"])
    if stuck and not state.get("stuck_alerted") == sorted(stuck):
        notify("Warning", f"{len(stuck)} card(s) still have no fetchable art after "
                          f"{ap.MAX_ATTEMPTS} daily attempts, e.g. {stuck[:3]}")
        state["stuck_alerted"] = sorted(stuck)
    go, reason, triggered = ap.decide(state["ledger"], now, force=args.force)
    print(f"[fp-auto] catalog casual-v{cat_v}: {len(missing)} missing; build={go} ({reason})",
          flush=True)
    pubs = state["published"]
    if go and pubs and now - datetime.fromisoformat(pubs[-1]["at"]) < timedelta(days=args.min_interval_days):
        go, reason = False, f"last publish {pubs[-1]['at']} is inside --min-interval-days"
        print(f"[fp-auto] holding: {reason}", flush=True)
    if not go:
        ap.save_state(args.state, state)
        if not args.dry_run:
            prune(args, state)
            ap.save_state(args.state, state)
        return 0

    # --- stage 1: incremental build ---------------------------------------------------------
    new_db = os.path.join(args.work, "new.sqlite")
    shutil.copyfile(live_db, new_db)
    bf = _load_script("build_fingerprints")
    loader = bf.make_cached_loader(args.cache_dir) if args.cache_dir else bf.make_cached_loader()
    stats = build.build_fingerprints(catalog, new_db, book, loader,
                                     built_at=now.isoformat().replace("+00:00", "Z"))
    print(f"[fp-auto] build: {stats}", flush=True)
    still_missing = ap.missing_card_ids(catalog, new_db)
    for cid in still_missing:
        state["ledger"][cid]["attempts"] += 1
    added = len(missing) - len(still_missing)
    if added <= 0:
        ap.save_state(args.state, state)
        if triggered:
            notify("Warning", f"build added 0 cards ({len(still_missing)} still have no usable "
                              "art); nothing published.")
        return 0

    # --- stages 2-3: stage + validate -------------------------------------------------------
    version = ap.next_version(nas_m["version"], r2_m and r2_m.get("version"),
                              ap.part_versions(nas_parts))
    live_size = nas_m["sizeBytes"]
    try:
        manifest, stage = stage_and_validate(args, new_db, live_db, version, live_size, codebook_hash)
    except RuntimeError as e:
        ap.save_state(args.state, state)
        notify("Error", f"scanner pack v{version} NOT published: {e}"[:700])
        return 1
    if args.dry_run:
        ap.save_state(args.state, state)
        print(f"[fp-auto] DRY RUN: v{version} (+{added} cards) validated, not shipped", flush=True)
        return 0

    # --- stage 4: ship ----------------------------------------------------------------------
    try:
        ship(args, manifest, stage, state)
    except Exception as e:  # noqa: BLE001
        ap.save_state(args.state, state)
        notify("Error", f"scanner pack v{version} ship FAILED and was rolled back: {e}"[:700])
        return 1
    pubs.append({"version": version, "at": now.isoformat(), "added": added})
    for cid in [k for k in state["ledger"] if k not in still_missing]:
        state["ledger"].pop(cid, None)
    ap.save_state(args.state, state)
    notify("Success", f"scanner pack v{version} published (+{added} cards, "
                      f"{len(manifest['parts'])} parts, {manifest['sizeBytes']} B) to NAS and R2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
