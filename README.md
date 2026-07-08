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

### Build the tool

```bash
# From the sead-service repo root
cmake -B build -DBUILD_TOOLS=ON && cmake --build build -j
```

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
./bin/stardome-client --port /dev/ttyUSB0 endorse \
  --org-id <org_id_hex> \
  --org-pk <org_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-tree module_tree.bin \
  --out-attestation module_att.bin
```

The output prints the `merkle_root` hex and `xmss_sig` hex. Use these
with `gen-bootstrap` in the next step. The `endorse` command reuses the
standard `FLAG_SIGN` wire path — no firmware changes needed.

> **Note on timestamps:** `--not-before` defaults to current time,
> `--not-after` defaults to `0` (no expiry). The org admin and module
> operator must agree on the same timestamps — the values passed here
> must exactly match the values passed to `gen-bootstrap` in the next
> step, because the module's Merkle tree commits to them.

### 3b — Register the organization (OrgGenesis)

```bash
./build/tools/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --module-id <module_id_hex> \
  --module-pk <module_pk_hex> \
  --module-merkle-root <merkle_root_hex> \
  --module-signature <sig_hex>
```

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
./build/tools/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --edge-id <edge_id_hex> \
  --edge-pk <edge_pk_hex>
```

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
# Build the gen-token tool (from the sead-service repo)
cmake -B build -DBUILD_TOOLS=ON && cmake --build build -j

# Generate a token bound to an artifact
./build/tools/gen-token \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --payload-file artifact.cbor

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