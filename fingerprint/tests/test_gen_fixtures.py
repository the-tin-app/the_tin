import os, subprocess, json
from fpcore import constants as c

def test_gen_writes_references():
    subprocess.run(["python", "scripts/gen_fixtures.py"], check=True)
    for name in ("card_a", "card_b"):
        p = f"tests/fixtures/{name}.ref.json"
        assert os.path.exists(p)
        doc = json.load(open(p))
        assert doc["n"] > 20  # a real card yields plenty of keypoints
    params_path = "tests/fixtures/params.json"
    assert os.path.exists(params_path)
    params = json.load(open(params_path))
    # Assert against constants, not literals: this test went red at the nf=300 -> 650
    # and fp_version 1 -> 3 bumps because it hardcoded the old values. Its job is
    # "gen_fixtures emits the CURRENT params", not "the params are these numbers".
    assert params["fp_version"] == c.FP_VERSION
    assert params["canon_w"] == c.CANON_W and params["canon_h"] == c.CANON_H
    assert params["orb"]["nfeatures"] == c.ORB_PARAMS["nfeatures"]
