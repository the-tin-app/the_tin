#!/usr/bin/env python3
"""Minimal App Store Connect REST client (ES256 JWT auth).

Credentials come from the environment — NOTHING secret lives in this repo:
    ASC_ISSUER    App Store Connect issuer id (UUID)
    ASC_KEY_ID    key id, e.g. ABCDE12345
    ASC_KEY_PATH  path to AuthKey_<KEY_ID>.p8  (default ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8)

Usage:
    ios/scripts/asc.py GET  "/v1/apps?filter[bundleId]=ai.reyes.thetin"
    ios/scripts/asc.py POST "/v1/betaAppReviewSubmissions" '{"data":{...}}'

The Tin: app id 6788516920, bundle ai.reyes.thetin.
"""
import json, os, sys, time, base64, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

ISSUER = os.environ.get("ASC_ISSUER")
KEY_ID = os.environ.get("ASC_KEY_ID")
KEY_PATH = os.environ.get("ASC_KEY_PATH") or (
    os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8") if KEY_ID else None
)
BASE = "https://api.appstoreconnect.apple.com"


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def make_jwt():
    if not (ISSUER and KEY_ID and KEY_PATH):
        sys.exit("Set ASC_ISSUER, ASC_KEY_ID (and optionally ASC_KEY_PATH). See script header.")
    with open(KEY_PATH, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    si = _b64u(json.dumps(header).encode()) + b"." + _b64u(json.dumps(payload).encode())
    der = key.sign(si, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)  # ASC needs raw R||S (64 bytes), not DER
    return (si + b"." + _b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + make_jwt())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: asc.py <METHOD> <PATH> [JSON_BODY]")
    method, path = sys.argv[1].upper(), sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, payload = request(method, path, body)
    print(f"HTTP {status}")
    print(json.dumps(payload, indent=2) if isinstance(payload, (dict, list)) else payload)
    sys.exit(0 if 200 <= status < 300 else 1)
