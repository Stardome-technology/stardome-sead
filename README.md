# Stardome SEAD

**SEAD** — Stardome Edge Accountability DAG. A tamper-evident event
log for edge device accountability, built on XMSS post-quantum signatures.

This guide walks you through deploying a SEAD instance: generate keys,
start the stack, register your organization, authorize an edge, and
produce tokens for IPFS pinning.

## Architecture

- **sead-core** — event store, DAG maintenance, org/edge key resolution
- **edge-service** — ingest, receipt, commit, and retrieval APIs
- **storage-gateway** — evidence artifact distribution (IPFS-backed)
- **auth-service** — token verification for external services
- **verifier-service** — independent verification of event chains
- **source-data-service** — controlled disclosure of source data

---

## Step 1 — Generate keys

Run on a **secure, offline laptop**. The org signing key is the root of
trust — never store it on a server, never commit it to git, never
transmit it over the network.

```bash
# Pull the keygen image (public, no auth needed)
docker pull ghcr.io/stardome-technology/stardome-sead/keygen:latest

# Generate an organization keypair (used for auth tokens)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label org

# Generate an edge DAG signing keypair
# (separate from the org key — edge signs commits, org signs tokens)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label edge

# See all supported OIDs and options
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --help
```

Each run prints `ID`, `SECRET_KEY`, and `PUBLIC_KEY` in hex. Save these
values — you will need them for configuration and bootstrap.

> **Note:** `--label` is just a printed annotation (e.g. `── Label: org ──`).
> The actual `ID`, `SECRET_KEY`, and `PUBLIC_KEY` lines are always hex
> strings regardless of the label you choose. `--label` does not affect
> the key material. All tools (`gen-bootstrap`, `gen-token`, `endorse`)
> expect these hex values, not the label text.

---

## Step 2 — Deploy the stack

### Prerequisites

- Docker + Docker Compose plugin
- The key values from Step 1

### Configure

Create a `.env` file with your key values:

```bash
cat > .env << EOF
EDGE_ORG_ID=<org_id_hex>
EDGE_ID=<edge_id_hex>
EDGE_SIGNING_KEY=<edge_secret_key_hex>
EDGE_ORG_SIGNING_KEY=<org_secret_key_hex>
EDGE_ORG_PUBLIC_KEY=<org_public_key_hex>
EOF
```

### Start

Pull the latest images, then start the stack:

```bash
docker compose -f docker-compose.remote.yml pull
docker compose -f docker-compose.remote.yml up -d

# Verify all services are healthy
curl http://localhost:8080/health
```

### Configuration reference

| Variable | Service | Required | Default | Description |
|----------|---------|----------|---------|-------------|
| `LOG_LEVEL` | all | No | `info` | Logging verbosity |
| `SEAD_CORE_PORT` | sead-core | No | `8080` | HTTP port |
| `EDGE_ORG_ID` | edge-service | **†** | — | Organization ID (hex) |
| `EDGE_ID` | edge-service | **†** | — | Edge device ID (hex) |
| `EDGE_SIGNING_KEY` | edge-service | **†** | — | Edge XMSS private key (hex) |
| `EDGE_ORG_SIGNING_KEY` | edge-service | **†** | — | Org XMSS key for auth tokens (hex) |
| `EDGE_ORG_PUBLIC_KEY` | edge-service | No | — | Org XMSS public key (hex) |
| `EDGE_TOKEN_TTL` | edge-service | No | `300` | Auth token TTL in seconds |
| `EDGE_STORAGE_GATEWAY_URL` | edge-service | No | `http://localhost:8082` | Storage gateway URL |
| `EDGE_WATCHDOG_INTERVAL_SEC` | edge-service | No | `30` | Watchdog interval |
| `EDGE_COMMIT_STRATEGY` | edge-service | No | `single` | `single` or `batch` |
| `EDGE_BATCH_FLUSH_INTERVAL_SEC` | edge-service | No | `300` | Batch flush interval |
| `STORAGE_GATEWAY_PORT` | storage-gateway | No | `8082` | HTTP port |
| `IPFS_API_BASE_URL` | storage-gateway | No | `https://ipfs.stardome.cloud` | IPFS API endpoint |
| `AUTH_SKEW_TOLERANCE_SEC` | auth-service | No | `30` | Token expiry skew tolerance |
| `AUTH_KEY_CACHE_TTL_SEC` | auth-service | No | `60` | Org key cache TTL |
| `VERIFIER_SOURCE_DATA_BASE_URL` | verifier-service | No | `http://source-data-service:8085` | Source-data URL |
| `SOURCE_DATA_TRUSTED_VERIFIERS` | source-data-service | No | — | Comma-separated hex org_ids |

---

## Step 3 — Bootstrap genesis

Before the DAG accepts events, register your organization and authorize
your edge. The easiest way is using the `gen-bootstrap` tool, which
builds and signs the CBOR envelopes for you.

### 3a — Generate the module endorsement signature

The OrgGenesis event requires a **module endorsement signature**: an XMSS
signature produced by the Stardome hardware module (SGE/SSP) over the
CBOR array `[org_id, org_pk, not_before, not_after]`. This proves the
module's XMSS key is installed in a genuine Stardome device.

The module's XMSS private key lives inside the hardware — it cannot be
exported. You must connect the module via UART and use
`stardome-client endorse` to request the signature.

#### Generate the signature

```bash
# Request the module to sign the org-endorsement payload.
# The 4 values (org_id, org_pk, not_before, not_after) are placed as
# source-data leaves in the module's Merkle tree. The module signs
# the tree root and returns the attestation.
# If using the provided stardome-client on a local Stardome module:
./bin/stardome-client --port /dev/ttyUSB0 endorse \
  --org-id <org_id_hex> \
  --org-pk <org_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-tree module_tree.bin \
  --out-attestation module_att.bin
  --quiet
```

The command prints the required hex values to stdout. You do **not** need
to manually parse the binary files — the tool already shows:

```
Module XMSS public key:
  <module_pk_hex>

Merkle root (32 bytes):
  <merkle_root_hex>

XMSS signature (<N> bytes):
  <sig_hex>

Use with gen-bootstrap:
  --module-merkle-root <merkle_root_hex>
  --module-signature <sig_hex>
```

Copy these values for the next step. The `endorse` command reuses the
standard `FLAG_SIGN` wire path — no firmware changes needed.

> **Important — timestamps are UNIX epoch seconds.**
> `not_before` and `not_after` are **UNIX epoch seconds** (UTC), e.g.
> `1770336000` for 2026-03-01T00:00:00Z. The server compares them
> numerically and rejects `not_before > not_after`. This is **not**
> an opaque byte comparison — the values encode a real validity window.
>
> Get the current UNIX timestamp:
> ```bash
> date +%s
> ```
>
> Convert a date to UNIX seconds:
> ```bash
> date -d "2026-03-01 00:00:00 UTC" +%s
> ```
>
> `--not-before` defaults to `$(date +%s)` if omitted.
> `--not-after` defaults to `0` (no expiry) if omitted.
>
> **Critical:** The `org-genesis` command below **must** receive the
> EXACT SAME `--not-before` and `--not-after` integer values, because the
> Merkle tree leaf committed to those raw bytes. Passing no values uses
> defaults that must match within the same second — **always pass them
> explicitly to avoid clock-skew mismatch.**

### 3b — Register the organization (OrgGenesis)

The `gen-bootstrap` tool can read the attestation file directly from step 3a.
It is available as a Docker image — no source build needed:

```bash
# Pull the gen-bootstrap image (public, no auth needed)
docker pull ghcr.io/stardome-technology/stardome-sead/gen-bootstrap:latest

# Register the org — feed the attestation binary directly.
# Mount the current directory so the tool can read the attestation file:
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --attestation-file /data/module_att.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

The `--attestation-file` option extracts the module's public key, Merkle root,
and XMSS signature from the attestation CBOR binary, and derives the
`module_id` as `SHAKE256(module_pk)` automatically.

Alternatively, you can pass individual module arguments (legacy):

```bash
docker run --rm ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --module-id <module_id_hex> \
  --module-pk <module_pk_hex> \
  --module-merkle-root <merkle_root_hex> \
  --module-signature <sig_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

The `--not-before` and `--not-after` values **must** match exactly what
you passed to `stardome-client endorse` in step 3a. If omitted, the tool
defaults to the current time (`not_before`) and `0` (`not_after`), which
will cause a signature mismatch if the endorsement was generated with
different values.

This outputs a hex string. POST it to sead-core:

```bash
curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"envelope_hex": "<paste hex output here>"}'
```

**What's inside the envelope** — the CBOR body is equivalent to this JSON:

```json
{
  "org_id": <hex bytes>,
  "org_pk": <hex bytes>,
  "not_before": <unix timestamp>,
  "not_after": <0 or timestamp>,
  "module_endorsements": [
    [<module_id_hex>, <module_pk_hex>, <merkle_root_hex>, <sig_hex>]
  ]
}
```

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier (SHAKE256 of public key) |
| `2` | `org_pk` | bytes | Organization's XMSS public key |
| `3` | `not_before` | unsigned int | Validity start (UNIX epoch seconds) |
| `4` | `not_after` | unsigned int | Validity end (`0` = no expiry) |
| `5` | `module_endorsements` | array | Array of `[module_id, module_pk, merkle_root, signature]` |

The envelope is signed by the **org key** (the same keypair being
registered). This bootstraps the org's identity in the DAG.

### 3c — Authorize the edge (EdgeAuthorization)

```bash
docker run --rm ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --edge-id <edge_id_hex> \
  --edge-pk <edge_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

The `--not-before` and `--not-after` default to `now` and `0` respectively
if omitted. The `not_before`/`not_after` here are the edge's authorization
window — independent of the org genesis values.

POST the output hex to sead-core:

```bash
curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"envelope_hex": "<paste hex output here>"}'
```

**What's inside** — equivalent JSON:

```json
{
  "org_id": <hex bytes>,
  "edge_id": <hex bytes>,
  "edge_pk": <hex bytes>,
  "not_before": <unix timestamp>,
  "not_after": <0 or timestamp>
}
```

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier |
| `2` | `edge_id` | bytes | Edge device identifier |
| `3` | `edge_pk` | bytes | Edge device's XMSS public key |
| `4` | `not_before` | unsigned int | Authorization start (UNIX epoch seconds) |
| `5` | `not_after` | unsigned int | Authorization end (`0` = no expiry) |

The envelope is signed by the **org key** (the same one registered in
step 3b). This proves the org authorizes this edge.

### Envelope structure (both events)

Every event is wrapped in a `SeadEnvelope`. The `gen-bootstrap` tool
builds this for you, but here is what it contains:

```json
{
  "protocol_version": "1.1.2",
  "event_type": <1 or 10>,
  "event_id": <32 bytes hex>,
  "body": <canonical CBOR bytes hex>,
  "signature": <XMSS signature bytes hex>
}
```

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `protocol_version` | text string | Always `"1.1.2"` |
| `2` | `event_type` | unsigned int | `1` = OrgGenesis, `10` = EdgeAuthorization |
| `3` | `event_id` | bytes (32) | SHAKE256 hash of canonical CBOR of the body |
| `4` | `body` | bytes | Canonical CBOR of the inner event body |
| `5` | `signature` | bytes | XMSS signature over `{event_type, event_id}` |

### Verify

```bash
curl http://localhost:8080/orgs/<org_id_hex>
# Expected: {"status":"active","org_pk_hex":"<pk>"}

curl http://localhost:8080/edges/<org_id_hex>/<edge_id_hex>
# Expected: {"status":"authorized","edge_pk_hex":"<pk>"}
```

---

## Step 4 — Generate auth tokens (IPFS pinning)

The auth stack only verifies tokens — it never generates them. You produce
tokens on the **same secure laptop** from Step 1, using the `gen-token`
tool. The org signing key never leaves your machine.

```bash
# Pull the gen-token image (public, no auth needed)
docker pull ghcr.io/stardome-technology/stardome-sead/gen-token:latest

# Generate a token bound to an artifact
# Mount the directory containing the payload file:
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-token \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --payload-file /data/artifact.cbor

# Output: a single line of base64url-encoded CBOR
# Ready for: Authorization: Bearer <token>
```

### Token structure

See [sead_auth_token_v1.0.0.cddl](https://github.com/Stardome-technology/stardome-cbor-schemes/blob/main/sead_auth_token_v1.0.0.cddl)

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier |
| `2` | `scope` | text string | `"ipfs_pin"` |
| `3` | `expiry` | unsigned int | UNIX timestamp |
| `4` | `nonce` | bytes (16) | Random challenge |
| `5` | `signature` | bytes | XMSS signature over fields 1-4 |
| `8` | `payload_hash` | bytes (32) | (optional) Binds token to a specific artifact |

Token is **base64url-encoded** CBOR (`RFC 4648 §5`, no padding).

---

## Next steps

- **IPFS auth** — Deploy the minimal auth stack alongside an IPFS node:
  [stardome-ipfs](https://github.com/Stardome-technology/stardome-ipfs)
- **Explorer** — Read-only operational dashboard:
  [stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer)
- **Full bootstrap reference** — Detailed CBOR assembly and edge cases:
  [`docs/bootstrap-genesis.md`](docs/bootstrap-genesis.md)