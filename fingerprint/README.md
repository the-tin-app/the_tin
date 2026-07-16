# fingerprint

Offline card-fingerprint tooling (Python side). This package (`fpcore`) is the
server/reference-side implementation of the ORB-based card fingerprint format
used for cross-side (device ↔ server) parity matching with the iOS scanner —
see `fpcore/constants.py` for the single Python source of truth for the
fingerprint format, mirrored on iOS via `FingerprintParams.h` /
`FingerprintConstants.swift` and guarded by
`ios/TheTin/Tests/FingerprintConstantsParityTests.swift`.

## Setup

**Requires Python 3.11.** The default `python3` on recent macOS is often 3.14,
which has no prebuilt wheel for the pinned `opencv-python-headless==4.9.0.80`
(and building from source is impractical). Use `python3.11` explicitly:

```sh
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"
```

## Tests

```sh
pytest
```

## Regenerating fixtures

`scripts/gen_fixtures.py` regenerates the checked-in parity reference JSONs
(`tests/fixtures/*.ref.json`) and the cross-language constants snapshot
(`tests/fixtures/params.json`) from the fixture images. Run it whenever
`FP_VERSION`, the ORB params, or the fixture images change, and copy
`params.json` into `ios/TheTin/Tests/Fixtures/Fingerprint/params.json`.
