# Stardome SEAD

**SEAD** — Stardome Edge Accountability DAG. A tamper-evident event
log for edge device accountability, built on XMSS post-quantum signatures.

This guide walks you through deploying a SEAD instance: generate keys,
start the stack, register your organization, authorize an edge, and
produce tokens for IPFS pinning.

## Architecture

- **gateway** — single public HTTPS entry point (Go). Terminates TLS, enforces
  auth, validates requests, and routes to the internal C++ services over gRPC.
  `auth-service` and `verifier-service` are collapsed into the gateway.
- **sead-core** — event store, DAG maintenance, org/edge key resolution (gRPC-only)
- **edge-service** — ingest, receipt, commit, and retrieval APIs (gRPC-only)
- **storage-gateway** — evidence artifact distribution (IPFS-backed) (gRPC-only)
- **source-data-service** — controlled disclosure of source data (gRPC-only)
- **gossip-node** — C2 sync observer (Go): native libp2p Gossipsub frontier
  dissemination + DHT/mDNS peer discovery + gRPC fetch/validate.

> **Go Gateway migration (phase 4.4):** the C++ services are **gRPC-only** and
> publish no public HTTP ports. They are reachable only on the internal
> `sead-network` bridge via the Go gateway. `auth-service` and `verifier-service`
> are collapsed into the gateway (no longer standalone services). Health is
> probed via `grpc.health.v1.Health`.

> **Sync transport (gossip):** the sync path is a **native libp2p Gossipsub
> mesh** via `gossip-node`. `gossip-node` runs its own libp2p peer (port 31002),
> publishes/subscribes frontiers on `sead-sync/{org}` topics, and
> fetches/validates events over gRPC (local sead-core + gateway). No HTTP/SSE
> in the sync path.

> **⚠️ Public port convention:** The published host port `30080` (gateway) is
> **standardized across all public deployments** and must not be changed in this
> compose file. If you need a different port, override it via environment
> variables or maintain your own copy of the compose file. The internal gRPC
> ports (`50051`–`50055`) are private to the stack and can be freely customized.

## Public ports to open

For an integrator deploying this stack, these are the **public** host ports that
must be reachable from outside (open in the firewall / cloud security group):

- **`30080/tcp`** — gateway HTTPS API (all public endpoints: event store, org/edge
  key resolution, cross-org event fetch, ingest, receipts, verification)
- **`31002/tcp`** — gossip-node libp2p peer. The sync mesh dials
  peer nodes on this port (`/ip4/<ip>/tcp/31002`). Must be reachable between
  nodes for cross-node frontier dissemination + event fetch.

All other service ports (`50051`–`50055`) are **private** to the Docker network
and should **not** be exposed publicly. If you only need local access, you can
leave `30080` closed to the internet and reach it via `localhost`.

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
# Gateway auth (required in production — see the gateway README)
SEAD_AUTH_SECRET=<shared-secret>
# gossip-node (C2 sync observer): this node's own org + orgs it observes.
GOSSIP_ORG_ID=<org_id_hex>            # same value as EDGE_ORG_ID
GOSSIP_OBSERVE_ORGS=<other_org_id_hex>,<another_org_id_hex>
GOSSIP_BOOTSTRAP=/ip4/<peer-ip>/tcp/31002/p2p/<peerid>
EOF
```

> **Key env for the gossip sync** — `GOSSIP_ORG_ID` configures the
> `gossip-node` C2 observer (its own org, always observed). `GOSSIP_OBSERVE_ORGS`
> enables cross-node sync: the node subscribes to each listed org's
> `sead-sync/{org}` topic and publishes frontiers for it. Observation is
> **unilateral** — no publisher consent needed, so each node simply lists the
> orgs it wants to verify for. `GOSSIP_BOOTSTRAP` lists the other nodes'
> libp2p multiaddrs (`/ip4/<ip>/tcp/31002/p2p/<peerid>`); mDNS/DHT also
> auto-discover peers on the same subnet.

> **How a node finds the orgs it observes — bootstrap vs. catalog.**
> `GOSSIP_BOOTSTRAP` is only a **transport-level entry point**: it tells the
> node which peer(s) to dial to join the mesh. It is **not** org-specific and
> does **not** need to be a node of the observed org — any reachable peer in
> the mesh works, because Gossipsub relays messages on the subscribed topics.
> The *authoritative* answer to "which nodes represent org X, and at which
> endpoints" is the org's **replication endpoint catalog** — an org-signed DAG
> event (`replication_endpoint_catalog`, event_type 60) that each org publishes
> to assert its own replication nodes. So:
>
> - **To be discoverable**, an org's operator must publish a catalog listing
>   their nodes (node_id + reachable addresses). This is an org decision, like
>   authorizing an edge — it is not inferred from the mesh.
> - **To bootstrap**, a node only needs *one* reachable peer to join the mesh
>   (via `GOSSIP_BOOTSTRAP`, mDNS, or DHT). Once in the mesh it can receive the
>   observed orgs' catalogs and frontiers.
> - The bootstrap peer can be shared out-of-band by any means (IP, DNS, a
>   partner's node) — it does not have to be published in the SEAD DAG. The
>   catalog is what makes an org's nodes *authoritatively* discoverable.
> - **Bootstrap vs. catalog membership is an integrator decision.** A node you
>   share as a bootstrap entry point is a value you **MAY** let a partner
>   organization use for bootstrapping — it is **not** assumed to be part of
>   the catalog set and publish flow. It may or may not be, depending on the
>   integrator's choice: you can keep a **static bootstrap node** and update
>   the frontier-dispatching nodes over time via catalogs, or use the same
>   node(s) for both scopes. The two roles are independent.
>
> **Trust model:** bootstrapping is *transport only* — dialing a peer does not
> mean trusting its org. Trust comes from the DAG (org genesis → edge
> authorization → XMSS signatures), never from who you dialed. A bootstrap peer
> can relay or withhold gossip (availability), but it cannot forge org-signed
> events (integrity). Only catalog-listed, org-signed endpoints are
> authoritative for an org's membership.

> **Cross-node sync (DAG-native auth replication)** — when a node observes
> another org, foreign `edge_commit` events are validated only **after** their
> authorization graph (`edge_authorization` → `org_genesis`) is replicated to
> the local `sead-core`. `gossip-node` recursively fetches these dependencies
> (via the events' `dependency_refs` field, with indexed fallback for events
> without explicit refs), submits them in topological order, and holds events
> that await dependencies until they resolve. There is **no trusted-sync
> bypass**: every foreign event still passes sead-core's normal
> signature-verification path. Genuinely invalid events are rejected and
> dropped, never retried.

### Start

Pull the latest images, then start the stack:

```bash
docker compose -f docker-compose.remote.yml pull
docker compose -f docker-compose.remote.yml up -d

# Verify the gateway is healthy (TLS on by default; -k for self-signed)
curl -k https://localhost:30080/health
```

> **⚠️ About `-k` in the curl examples below.** The `-k` flag disables TLS
> certificate verification. It is used throughout this guide because the
> **isolated/own-party** deployment uses a **self-signed** cert, which curl
> would otherwise reject. For a **production/cross-org** deployment with a
> **public cert** (e.g. Let's Encrypt), **drop `-k`** so the standard PKI
> trust store verifies the gateway — or, for a private CA, replace `-k` with
> `--cacert <ca.crt>` to trust that specific CA. Using `-k` against a public
> cert silently disables the very verification the cert is meant to provide.
>
> The examples below use a `$CURL_TLS` variable so you can set it once per
> shell: `export CURL_TLS="-k"` (self-signed/isolated) or
> `export CURL_TLS=""` / `export CURL_TLS="--cacert /path/to/ca.crt"`
> (public/private CA). The health check above keeps `-k` inline for brevity.

> **⚠️ Gateway TLS — you must provide a certificate.** The gateway terminates
> TLS using the cert/key you point `GATEWAY_TLS_CERT`/`GATEWAY_TLS_KEY` at
> (default `/etc/gateway/certs/server.crt` / `.key`, mounted from `./secrets`).
> If you start the stack without placing `server.crt` + `server.key` in
> `./secrets/`, the gateway will fail to serve HTTPS. See the
> [gateway README — TLS section](https://github.com/Stardome-technology/stardome-sead-gateway#tls-public-cert-production-vs-self-signed-isolatedown-party)
> for how to choose between a public cert (production/cross-org) and a
> self-signed cert (isolated/own-party), and how to generate them.

### Configuration reference

| Variable | Service | Required | Default | Description |
|----------|---------|----------|---------|-------------|
| `LOG_LEVEL` | all | No | `info` | Logging verbosity |
| `EDGE_ORG_ID` | edge-service | **†** | — | Organization ID (hex) |
| `EDGE_ID` | edge-service | **†** | — | Edge device ID (hex) |
| `EDGE_SIGNING_KEY` | edge-service | **†** | — | Edge XMSS private key (hex) |
| `EDGE_ORG_SIGNING_KEY` | edge-service | **†** | — | Org XMSS key for auth tokens (hex) |
| `EDGE_ORG_PUBLIC_KEY` | edge-service | No | — | Org XMSS public key (hex) |
| `EDGE_TOKEN_TTL` | edge-service | No | `300` | Auth token TTL in seconds |
| `EDGE_STORAGE_GATEWAY_URL` | edge-service | No | `storage-gateway:50052` | Storage gateway gRPC target |
| `EDGE_WATCHDOG_INTERVAL_SEC` | edge-service | No | `1` | DAG commit (watchdog) cadence in seconds — near-realtime commit publish |
| `EDGE_PIN_INTERVAL_SEC` | edge-service | No | `30` | IPFS pin loop cadence (independent, slow) |
| `EDGE_PIN_MAX_RETRIES` | edge-service | No | `-1` | Max pin retries (`-1` = unlimited) |
| `EDGE_PIN_BACKOFF_BASE_SEC` | edge-service | No | `30` | Pin retry exponential backoff base (seconds) |
| `EDGE_PIN_BACKOFF_CAP_SEC` | edge-service | No | `86400` | Pin retry max backoff delay (seconds) |
| `EDGE_COMMIT_STRATEGY` | edge-service | No | `single` | `single` or `batch` |
| `EDGE_BATCH_FLUSH_INTERVAL_SEC` | edge-service | No | `300` | Batch flush interval |
| `EDGE_AUTHORIZATION_EVENT_ID` | edge-service | No | *(auto)* | Event_id (64 hex) of the `edge_authorization` that activated this edge, written into each `edge_commit`'s `dependency_refs` so commits resolve to their authorization graph on-chain. **Optional** — if unset, edge-service auto-resolves it from sead-core at startup; set it to override |
| `IPFS_API_BASE_URL` | storage-gateway | No | `https://ipfs.stardome.cloud` | IPFS API endpoint |
| `SOURCE_DATA_TRUSTED_VERIFIERS` | source-data-service | No | — | Comma-separated hex org_ids |
| `GOSSIP_ORG_ID` | gossip-node | **†** | — | Org ID (hex, 64 chars) — same as `EDGE_ORG_ID`; gossip-node's own org (always observed) |
| `GOSSIP_OBSERVE_ORGS` | gossip-node | No | — | Comma-separated 64-hex org_ids this node observes (own org always observed). Enables cross-node sync |
| `GOSSIP_BOOTSTRAP` | gossip-node | No | — | Comma-separated libp2p multiaddrs of other nodes to dial at startup (`/ip4/<ip>/tcp/31002/p2p/<peerid>`). A **transport entry point** to join the mesh — not org-specific; any reachable peer works. mDNS/DHT also discover peers |
| `GOSSIP_LISTEN` | gossip-node | No | `/ip4/0.0.0.0/tcp/31002` | gossip-node libp2p listen multiaddr |
| `GOSSIP_HEARTBEAT_SEC` | gossip-node | No | `10` | Frontier publish interval (seconds) |
| `GOSSIP_CORE` | gossip-node | No | `sead-core:50051` | Local sead-core gRPC target |
| `GOSSIP_GATEWAY` | gossip-node | No | `gateway:50054` | Local gateway Sync gRPC target |
| `GOSSIP_MDNS` | gossip-node | No | `true` | Enable mDNS LAN peer discovery |
| `GOSSIP_DHT` | gossip-node | No | `true` | Enable Kademlia DHT peer discovery |
| `GOSSIP_PNET` | gossip-node | No | `false` | Enable private-network enforcement |
| `SEAD_AUTH_SECRET` | gateway | **†** | — | Shared secret the gateway requires as `Authorization: Bearer <value>` on its public HTTPS endpoints. It guards the gateway's **public** API (the gRPC calls between the internal C++ services and `gossip-node` do **not** use it). **Empty (`""`) disables auth** — the gateway then accepts any request with no token, which is only safe for a localhost/isolated node; any **non-empty** value becomes a hard, single accepted Bearer (not "any string"). Set it (e.g. `openssl rand -hex 32`) whenever `:30080` could be reached beyond your own host |
| `GATEWAY_TLS_ENABLED` | gateway | No | `true` | Enable TLS termination (set false to disable) |
| `GATEWAY_TLS_CERT` / `GATEWAY_TLS_KEY` | gateway | No | `/etc/gateway/certs/server.crt` / `.key` | TLS cert/key paths (mounted from `./secrets`). **Production/cross-org:** use a public cert (Let's Encrypt). **Isolated/own-party deployment:** self-signed is fine (see the gateway README for the distinction) |
| `GATEWAY_AUTH_CBOR_ENABLED` | gateway | No | `true` | CBOR auth-token verification (collapsed from auth-service) |
| `GATEWAY_METRICS_ENABLED` | gateway | No | `true` | Enable `/metrics` endpoint |
| `GATEWAY_HEALTH_BACKENDS` | gateway | No | `sead-core,edge-service,storage,source-data` | Backends the gateway `/health` probes |
| `SVC_SEAD_CORE_GRPC` | gateway | No | `sead-core:50051` | sead-core gRPC target |
| `SVC_EDGE_SERVICE_GRPC` | gateway | No | `edge-service:50055` | edge-service gRPC target |
| `SVC_STORAGE_GRPC` | gateway | No | `storage-gateway:50052` | storage-gateway gRPC target |
| `SVC_SOURCE_DATA_GRPC` | gateway | No | `source-data-service:50053` | source-data-service gRPC target |
| `GATEWAY_GRPC_PORT` | gateway | No | `50054` | Gateway Sync gRPC port |

> **Gateway config:** the full gateway configuration (TLS, auth, timeouts,
> gRPC targets) is documented in the
> [stardome-sead-gateway](https://github.com/Stardome-technology/stardome-sead-gateway)
> README. The gateway is the single public surface; the C++ services are
> gRPC-only and publish no public HTTP ports.

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
  --out-tree endorse_tree.bin \
  --out-attestation endorse_att.bin
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
# Mount the directory containing the attestation file and cd to the
# same relative location so the container sees the correct path.
# For example, if the attestation file is at ../signatures/endorse_att.bin:
cd ../signatures
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --attestation-file /data/endorse_att.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

> **Important:** Docker only sees files inside mounted volumes. The
> `--attestation-file` path must be inside a directory you passed with
> `-v`. If the file is elsewhere, mount that directory instead:
> `docker run --rm -v /absolute/path/to/signatures:/data ...`

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

This outputs a hex string. Use `--out-file` to write it to a file, then POST it:

```bash
# Write the envelope to a file (avoids terminal copy-paste issues)
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --attestation-file /data/endorse_att.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-file /data/envelope.hex

# POST the file contents as the JSON value
# (the gateway requires a Bearer token — set SEAD_AUTH_SECRET in .env)
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS -X POST https://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d "{\"envelope_hex\": \"$(cat envelope.hex)\"}"
```

> **Tip:** The envelope hex can be very large (XMSS signatures are ~18 KB).
> Using `--out-file` avoids terminal scroll and copy-paste truncation.

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
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --edge-id <edge_id_hex> \
  --edge-pk <edge_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-file /data/envelope.hex
```

The `--not-before` and `--not-after` default to `now` and `0` respectively
if omitted. The `not_before`/`not_after` here are the edge's authorization
window — independent of the org genesis values.

POST the output hex to sead-core (via the gateway):

```bash
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS -X POST https://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d "{\"envelope_hex\": \"$(cat envelope.hex)\"}"
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
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS https://localhost:30080/orgs/<org_id_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
# Expected: {"status":"active","org_pk_hex":"<pk>"}

curl $CURL_TLS https://localhost:30080/edges/<org_id_hex>/<edge_id_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
# Expected: {"status":"authorized","edge_pk_hex":"<pk>"}
```

---

## Step 4 — IPFS pinning

In the Go Gateway architecture, the **gateway** is the single public surface
for IPFS pinning. The `auth-service` and `verifier-service` are collapsed into
the gateway, and the C++ services are gRPC-only (no public HTTP ports).

### Pin an artifact

The gateway exposes `POST /pin` (native Go handler). It requires a valid CBOR
auth token for the target org, passed in the request body:

```bash
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS -X POST https://localhost:30080/pin \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d '{
    "artifact": "<artifact_hex>",
    "auth_token": "<base64url-encoded CBOR auth token>"
  }'

# Response:
# {
#   "cid": "<ipfs-cid>",
#   "payload_hash": "<hex>",
#   "status": "pinned"
# }
```

Retrieve a pinned artifact by its payload hash:

```bash
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS https://localhost:30080/cid/<payload_hash_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
```

> **Token minting:** the edge-service auto-generates per-pin auth tokens
> internally (signed by the org XMSS key) when it commits an artifact and
> pins it to IPFS via the storage gateway over gRPC. The standalone
> `POST /auth/token` HTTP endpoint on edge-service is **removed** in the
> Go Gateway migration — edge-service is gRPC-only. For the IPFS auth
> stack deployment (minimal sead-core + gateway), see
> [stardome-ipfs](https://github.com/Stardome-technology/stardome-ipfs).

### Token structure

See [sead_auth_token_v1.0.0.cddl](https://github.com/Stardome-technology/stardome-cbor-schemes/blob/main/sead_auth_token_v1.0.0.cddl)

| CBOR key | Field | Type | Description |
|----------|-------|------|-------------|
| `1` | `org_id` | bytes | Organization identifier |
| `2` | `scope` | text string | `"ipfs_pin"` |
| `3` | `expiry` | unsigned int | UNIX timestamp (`0` = no expiry) |
| `4` | `nonce` | bytes (16) | Random challenge |
| `5` | `signature` | bytes | XMSS signature over fields 1-4 |
| `8` | `payload_hash` | bytes (32) | (optional) Binds token to a specific artifact |

Token is **base64url-encoded** CBOR (`RFC 4648 §5`, no padding).

> **Note:** The standalone `gen-token` CLI tool exists for build-time
> testing but is **not recommended** for production use, because each
> invocation loads the key from hex and always starts at index 0.
> Prefer the edge-service's internal per-pin token generation to ensure
> the XMSS one-time index advances correctly.

---

## Next steps

- **IPFS auth** — Deploy the minimal auth stack alongside an IPFS node:
  [stardome-ipfs](https://github.com/Stardome-technology/stardome-ipfs)
- **Explorer** — Read-only operational dashboard:
  [stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer)
- **Full bootstrap reference** — Detailed CBOR assembly and edge cases:
  [`docs/bootstrap-genesis.md`](docs/bootstrap-genesis.md)