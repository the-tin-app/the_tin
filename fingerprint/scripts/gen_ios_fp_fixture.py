"""Build the 2-row iOS test fixtures from the committed server reference JSONs +
codebook.bin: a tiny fingerprints.sqlite (read by FingerprintStore/Matcher) and a
global-vec sidecar JSON (read by the parity gate). Run from fingerprint/.
Regenerate whenever FP_VERSION, the codebook, or the reference JSONs change."""
import base64, json
import numpy as np
from fpcore import codebook as cbmod, packing, fpdb

FIX = "../ios/TheTin/Tests/Fixtures/Fingerprint"
CARDS = ("card_a", "card_b")


def main():
    cb = cbmod.Codebook.load("fpcore/codebook.bin")
    sqlite_path = f"{FIX}/fingerprints-fixture.sqlite"
    import os
    for suffix in ("", "-wal", "-shm", "-journal"):
        try: os.remove(sqlite_path + suffix)
        except FileNotFoundError: pass

    conn = fpdb.open_db(sqlite_path)
    fpdb.write_meta(conn, cb.sha256_hex(), "2026-07-07T00:00:00Z")
    sidecar = {}
    for name in CARDS:
        doc = json.load(open(f"{FIX}/{name}.json"))
        n = doc["n"]
        desc = np.frombuffer(base64.b64decode(doc["descriptors_b64"]), np.uint8).reshape(n, 32)
        xy = np.array([[k[0], k[1]] for k in doc["keypoints"]], dtype=np.float32)  # already canonical px
        gvec = cb.global_vec(desc)                      # float16, L2-normalized tf-idf
        fpdb.write_card_fp(conn, name, packing.pack_global_vec(gvec), n,
                           packing.pack_keypoints(xy), packing.pack_descriptors(desc))
        sidecar[name] = [float(x) for x in gvec]        # f16 values upcast for JSON
    conn.close()
    json.dump(sidecar, open(f"{FIX}/global-vec-fixture.json", "w"))
    print(f"wrote {sqlite_path} + global-vec-fixture.json ({len(CARDS)} cards)")


if __name__ == "__main__":
    main()
