import os, subprocess, json

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
    assert params["fp_version"] == 1
    assert params["canon_w"] == 660 and params["canon_h"] == 920
    assert params["orb"]["nfeatures"] == 300
