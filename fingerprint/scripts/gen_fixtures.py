"""Regenerate the checked-in parity reference JSONs from the fixture images.
Run whenever FP_VERSION or the fixtures change."""
import json
import cv2
from fpcore.canonicalize import canonicalize
from fpcore import descriptors as d
from fpcore import constants as c

FIXTURES = ["card_a", "card_b"]

def main():
    for name in FIXTURES:
        img = cv2.imread(f"tests/fixtures/{name}.png", cv2.IMREAD_COLOR)
        kps, desc = d.extract(canonicalize(img))
        d.write_reference(f"tests/fixtures/{name}.ref.json", kps, desc)
        print(f"wrote tests/fixtures/{name}.ref.json ({len(kps)} kps)")

    with open("tests/fixtures/params.json", "w") as f:
        json.dump(c.params_dict(), f)
    print("wrote tests/fixtures/params.json")

if __name__ == "__main__":
    main()
