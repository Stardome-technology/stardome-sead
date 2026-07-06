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

Before the DAG accepts events, register `OrgGenesis` and `EdgeAuthorization`:

```bash
curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"envelope_hex": "<org_genesis_cbor_hex>"}'

curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"envelope_hex": "<edge_auth_cbor_hex>"}'
```

## IPFS auth

For deploying the minimal auth stack alongside an IPFS node, see
[stardome-ipfs](https://github.com/Stardome-technology/stardome-ipfs).

## Explorer

For a read-only operational dashboard, see
[stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer).