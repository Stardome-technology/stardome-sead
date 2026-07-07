# Stardome SEAD

**SEAD** — Stardome Edge Accountability DAG. A tamper-evident event
log for edge device accountability, built on XMSS post-quantum signatures.

## Architecture

- **sead-core** — event store, DAG maintenance, org/edge key resolution
- **edge-service** — ingest, receipt, commit, and retrieval APIs
- **storage-gateway** — evidence artifact distribution (IPFS-backed)
- **auth-service** — token verification for external services
- **verifier-service** — independent verification of event chains
- **source-data-service** — controlled disclosure of source data

## Source repos

Source code is developed in private repositories. Pre-built Docker images
are published here for deployment.

## Deploy

### Prerequisites

- Docker + Docker Compose plugin
- XMSS keypair for your edge device and organization (generate one with
  the keygen Docker image — see below)

### Key generation

```bash
# Pull the keygen image (public, no auth needed)
docker pull ghcr.io/stardome-technology/stardome-sead/keygen:latest

# Generate an edge DAG signing key (default: XMSS-SHAKE_20_256)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label edge

# Generate an organization key (separate from edge key, used for auth tokens)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label org

# See all supported OIDs and options
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --help
```

The output includes the hex `ID` (derived from the public key hash), which becomes
`EDGE_ID` / `EDGE_ORG_ID` in configuration.

### Production deploy

```bash
# Create .env with your XMSS key values
cat > .env << EOF
EDGE_ORG_ID=<org_id_hex>
EDGE_ID=<edge_id_hex>
EDGE_SIGNING_KEY=<edge_secret_key_hex>
EDGE_ORG_SIGNING_KEY=<org_secret_key_hex>
EDGE_ORG_PUBLIC_KEY=<org_public_key_hex>
EOF

# Pull and run — compose reads .env automatically
docker compose -f docker-compose.remote.yml up -d

# Health check
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

## Bootstrap genesis

Before the DAG accepts events, you must register an organization and authorize
an edge. Events are CBOR structures defined in
[`sead_v1.1.2.cddl`](https://github.com/Stardome-technology/stardome-cbor-schemes/blob/main/sead_v1.1.2.cddl)
and sent inside a JSON wrapper:

```bash
curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"envelope_hex": "<hex-encoded-cbor-envelope>"}'
```

### Event envelope (outer wrapper)

Every event is wrapped in a `SeadEnvelope`:

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `protocol_version` | text string | Always `"1.1.2"` |
| `2` | `event_type` | unsigned int | `1` = OrgGenesis, `10` = EdgeAuthorization |
| `3` | `event_id` | bytes (32) | SHAKE256 hash of canonical CBOR of the body |
| `4` | `body` | bytes | Canonical CBOR of the inner event body |
| `5` | `signature` | bytes | XMSS signature over canonical CBOR of `{event_type, event_id}` |

The `envelope_hex` parameter is the **hex-encoding of the canonical CBOR bytes**
of this envelope (not a hex of a JSON). See the
[bootstrap guide](docs/bootstrap-genesis.md) for assembly steps.

### OrgGenesis body (event_type = 1)

Creates an organization with its public key and an initial module endorsement.

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier (SHAKE256 of public key) |
| `2` | `org_pk` | bytes | Organization's XMSS public key |
| `3` | `not_before` | unsigned int | Validity start (UNIX epoch seconds) |
| `4` | `not_after` | unsigned int | Validity end (`0` = no expiry) |
| `5` | `module_endorsements` | array | Array of `ModuleEndorsement` objects (see below) |

Each `ModuleEndorsement` is a 3-element array:

| Index | Field | Type | Description |
|-------|-------|------|-------------|
| `0` | `module_id` | bytes | Hardware module identifier |
| `1` | `module_xmss_pk` | bytes | Module's XMSS public key |
| `2` | `signature` | bytes | Module signature over `(org_id, org_pk, not_before, not_after)` |

The envelope signature must be produced by the **org writer key** — this is
the same keypair whose public key is being registered. This bootstraps the
org's identity in the DAG.

### EdgeAuthorization body (event_type = 10)

Authorizes an edge device to publish commits under an existing org.

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier |
| `2` | `edge_id` | bytes | Edge device identifier |
| `3` | `edge_pk` | bytes | Edge device's XMSS public key |
| `4` | `not_before` | unsigned int | Authorization start (UNIX epoch seconds) |
| `5` | `not_after` | unsigned int | Authorization end (`0` = no expiry) |

The envelope signature must be produced by the **org key** (the same one
registered via OrgGenesis). This proves the org authorizes this edge.

### Full procedure

See [`docs/bootstrap-genesis.md`](docs/bootstrap-genesis.md) for the complete
step-by-step guide including key generation, CBOR assembly, and token
generation for IPFS pinning.

## Token generation (IPFS pinning)

The org operator generates signed auth tokens on a secure laptop using the
`gen-token` tool. See [`docs/bootstrap-genesis.md`](docs/bootstrap-genesis.md) →
**Step 3** for the full reference.

### Auth token structure

See [sead_auth_token_v1.0.0.cddl](https://github.com/Stardome-technology/stardome-cbor-schemes/blob/main/sead_auth_token_v1.0.0.cddl)

CBOR map with:
- `org_id` — organization identifier
- `scope` — `"ipfs_pin"`
- `expiry` — UNIX timestamp
- `nonce` — random bytes
- `signature` — XMSS signature over canonical CBOR of fields 1-4
- `payload_hash` (optional) — binds token to a specific artifact

Token is **base64url-encoded** CBOR (`RFC 4648 §5`, no padding) and passed
as `Authorization: Bearer <token>`.

## IPFS auth

For deploying the minimal auth stack alongside an IPFS node, see
[stardome-ipfs](https://github.com/Stardome-technology/stardome-ipfs).

## Explorer

For a read-only operational dashboard, see
[stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer).