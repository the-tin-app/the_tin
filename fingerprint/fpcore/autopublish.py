"""Decision logic for the automated scanner-pack publish (see scripts/auto_publish.py).

Pure functions, no network and no NAS access, so every rule that decides *whether* and
*as which version* to publish is unit-testable. The orchestrator owns the I/O.
"""
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from . import build, constants as c

#: Decision 2026-11-13: any single new card is enough to publish.
MIN_NEW_CARDS = 1
#: Newly-seen cards wait this long before a build, so release-day art that 404s, and sets that
#: get amended, don't trigger a ~550 MB re-download for every device.
DEBOUNCE_DAYS = 2
#: A card whose art still can't be fetched after this many daily attempts stops triggering
#: builds (and is reported once) instead of causing a build every night forever.
MAX_ATTEMPTS = 7
#: v6 is deliberately skipped (corrupt, 2026-11-13); the first automated publish is v7.
MIN_VERSION = 7

_PART_VER_RE = re.compile(r"fingerprints-v(\d+)\.part\d{3}$")


def missing_card_ids(catalog_path: str, pack_path: str, fp_version: int = c.FP_VERSION) -> list:
    """Catalog cards that can be fingerprinted (have art) but have no row at `fp_version`.
    Uses the same FINGERPRINTABLE_WHERE as the build, so detect and build agree by construction."""
    cat = sqlite3.connect(f"file:{catalog_path}?mode=ro", uri=True)
    ids = [r[0] for r in cat.execute(
        f"SELECT id FROM card WHERE {build.FINGERPRINTABLE_WHERE}")]
    cat.close()
    pack = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    have = {r[0] for r in pack.execute("SELECT card_id FROM card_fp WHERE fp_version=?",
                                       (fp_version,))}
    pack.close()
    return sorted(i for i in ids if i not in have)


def load_state(path: str) -> dict:
    try:
        with open(path) as f:
            s = json.load(f)
    except (OSError, ValueError):
        s = {}
    s.setdefault("ledger", {})          # card_id -> {"first_seen": iso, "attempts": n}
    s.setdefault("published", [])       # [{"version", "at", "added"}] newest last
    return s


def save_state(path: str, state: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def update_ledger(ledger: dict, missing: list, now: datetime) -> dict:
    """Add newly-missing cards (first_seen=now), keep attempts for ones still missing, and drop
    cards that are no longer missing."""
    out = {}
    for cid in missing:
        out[cid] = ledger.get(cid) or {"first_seen": now.isoformat(), "attempts": 0}
    return out


def decide(ledger: dict, now: datetime, min_new: int = MIN_NEW_CARDS,
           debounce_days: int = DEBOUNCE_DAYS, max_attempts: int = MAX_ATTEMPTS,
           force: bool = False) -> tuple[bool, str, list]:
    """(build?, reason, card_ids_that_triggered). A card counts toward the trigger when it has
    been missing for at least `debounce_days` and has attempts left."""
    live = {k: v for k, v in ledger.items() if v["attempts"] < max_attempts}
    ripe = sorted(k for k, v in live.items()
                  if now - datetime.fromisoformat(v["first_seen"]) >= timedelta(days=debounce_days))
    if force and live:
        return True, f"forced: {len(live)} missing card(s)", sorted(live)
    if len(ripe) >= min_new:
        return True, f"{len(ripe)} card(s) missing for >= {debounce_days}d", ripe
    if live:
        return False, (f"{len(live)} card(s) missing but none past the {debounce_days}-day "
                       "debounce yet"), []
    return False, "pack is current", []


def stuck_cards(ledger: dict, max_attempts: int = MAX_ATTEMPTS) -> list:
    return sorted(k for k, v in ledger.items() if v["attempts"] >= max_attempts)


def next_version(nas_manifest_version, r2_manifest_version, nas_part_versions,
                 min_version: int = MIN_VERSION) -> int:
    """One above everything either origin has ever shown a client, and never below MIN_VERSION.
    Part files count even with no manifest naming them: a half-published or corrupt version may
    be partially cached on devices (part identity is pinned to the version)."""
    seen = [v for v in (nas_manifest_version, r2_manifest_version) if v] + list(nas_part_versions)
    return max([min_version - 1] + seen) + 1


def part_versions(parts_dir: str) -> set:
    try:
        names = os.listdir(parts_dir)
    except OSError:
        return set()
    return {int(m.group(1)) for n in names if (m := _PART_VER_RE.match(n))}


def prunable_versions(on_disk: set, referenced: set, keep_previous: int | None) -> list:
    """Part-file versions safe to delete: not referenced by ANY origin's live manifest and not
    the rollback target. The live-manifest guard matters because the NAS and R2 can briefly or
    persistently disagree; deleting what the lagging origin still serves would strand clients."""
    keep = set(referenced)
    if keep_previous:
        keep.add(keep_previous)
    return sorted(v for v in on_disk if v not in keep)


def pack_meta_matches(pack_path: str, codebook_hash: str) -> tuple[bool, str]:
    """An incremental build is only valid on a pack made with the same fp_version and codebook.
    A mismatch means someone retrained or changed the format: that is a deliberate full rebuild,
    never an automatic one."""
    conn = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    row = conn.execute("SELECT fp_version, codebook_hash FROM meta").fetchone()
    conn.close()
    if row is None:
        return False, "live pack has no meta row"
    if row[0] != c.FP_VERSION:
        return False, f"live pack fp_version={row[0]} but code is {c.FP_VERSION}"
    if row[1] != codebook_hash:
        return False, "live pack codebook_hash differs from the committed codebook"
    return True, ""


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)

