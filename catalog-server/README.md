# catalog-server

The server the app downloads card data from: a thin static file server for the catalog
tiers and the scanner fingerprint pack, gated behind Apple App Attest so the bytes are
only served to genuine installs.

It is deliberately small. No database beyond a SQLite file of attested device keys, no
application logic, no knowledge of what the catalog contains — the pipeline in
[`functions/`](../functions) builds the artifacts, this serves them.

## Routes

| Route | Method | What |
|---|---|---|
| `/health` | GET | Liveness probe |
| `/challenge` | GET | One-time challenge for App Attest |
| `/attest` | POST | Registers a device's App Attest key |
| `/assert` | POST | Exchanges an assertion for a session token |
| `/catalog/*` | GET | Catalog artifacts from `CATALOG_DIR` |
| `/fingerprint/*` | GET | Fingerprint pack parts from `FINGERPRINT_DIR` |

## Running it

```bash
cp .env.example .env      # fill in the two required values
docker compose up --build
```

`docker-compose.yml` mounts one host directory at `/data`, which must contain:

```
/data
├── catalog/              # artifacts written by the functions/ pipeline
├── fingerprint/          # fingerprint pack parts
├── devices.sqlite        # created on first run
└── apple-root-ca.pem     # Apple's App Attest root CA
```

Without Docker: `npm ci && npm run build && node dist/index.js`, with the variables
below set in the environment.

## Configuration

Read directly by the server (see `.env.example` for the compose-level names):

| Variable | Default | What |
|---|---|---|
| `PORT` | `8080` | Listen port |
| `CATALOG_DIR` | `/data/catalog` | Directory served at `/catalog/` |
| `FINGERPRINT_DIR` | `/data/fingerprint` | Directory served at `/fingerprint/` |
| `DEVICE_DB_PATH` | `/data/devices.sqlite` | Attested device keys |
| `SESSION_SECRET` | *required* | HMAC secret for session tokens — any long random string |
| `APP_ID` | *required* | `<TEAM_ID>.<BUNDLE_ID>`, e.g. `ABCDE12345.com.example.tin` |
| `APPLE_ROOT_CA_PATH` | *required* | Path to Apple's App Attest root CA certificate |
| `APP_ATTEST_ENVIRONMENT` | *required* | `development` for Xcode builds, `production` for TestFlight and App Store builds |
| `CAPTURE_ATTEST_PATH` | unset | Debug only: dumps the next attestation body to this path |

`APP_ATTEST_ENVIRONMENT` is the one that bites. A development-signed build attests as
`development` and a TestFlight or App Store build attests as `production`; a mismatch
fails every attestation with no other symptom.

## Tests

```bash
npm ci && npm test
```
