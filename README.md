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
- **storage-gateway** — evidence artifact distribution (gRPC-only); IPFS pinning is now owned by the `pin-service`
- **pin-service** — Go gRPC service (`sead_rpc.Storage`) that owns the IPFS boundary. Replaces the storage-gateway's IPFS pin leg. Provides `AddToIPFS` and `RetrieveFromIPFS` RPCs. Edge-service pins via this service on `pin-service:50056`
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
# --oid 0x12 = XMSS-SHAKE256_20_256 — the DAG signing scheme (tool default)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label org --oid 0x12

# Generate an edge DAG signing keypair
# (separate from the org key — edge signs commits, org signs tokens)
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --label edge --oid 0x12

# See all supported OIDs and options
docker run --rm ghcr.io/stardome-technology/stardome-sead/keygen --help
```

> **OID:** software DAG keys (org + edge) must use **`0x12`**
> (`XMSS-SHAKE256_20_256`, the default). `0x05` (`XMSSMT-SHA2_40/8_256`) exists
> only for hardware-attestation compatibility and is produced by the modules
> themselves — never use it for org/edge keys. Keys with any other OID are
> rejected by sead-core.

Each run prints `ID`, `SECRET_KEY`, and `PUBLIC_KEY` in hex. Save these
values — you will need them for configuration and bootstrap.

> **Note:** `--label` is just a printed annotation (e.g. `── Label: org ──`).
> The actual `ID`, `SECRET_KEY`, and `PUBLIC_KEY` lines are always hex
> strings regardless of the label you choose. `--label` does not affect
> the key material. All tools (`gen-bootstrap`, `gen-token`, `endorse`)
> expect these hex values, not the label text.

### XMSS key state persistence (org **and** edge keys)

XMSS is a **one-time** signature scheme: every signature burns the leaf index
embedded in the secret key, and reusing a leaf for two different messages
breaks the scheme. Both signing keys used by `edge-service` — the **org** key
(auth/pin tokens) and the **edge** key (`edge_commit` signatures) — therefore
persist their full signer state (the one-time index **and** the advanced
secret-key buffer, which carries the tree-authentication state) to the
`key_index` table in `/data/edge.db` after every signature, before the
signature is released. After any restart the signers resume from that stored
state and continue at the next unused leaf.

Consequences for operations:

- **`edge.db` is key material.** The `sead_data` volume holding `edge.db`
  must be backed up with the same care as the keys themselves.
- **`docker compose down -v`, or restoring a stale `edge.db` backup, is a
  key-rotation event** for both the org and the edge key — not a
  re-provisioning step. If the volume is lost, revoke and re-issue the
  affected keys (org revocation / edge revocation + new `edge_authorization`)
  instead of reusing them from a reset index.
- Deployments that published commits **before** state persistence existed must
  be seeded or rotated first (the `edge-index-audit` tool in the
  `stardome-sead-private` repo audits published leaf indices per key and can
  seed the store; if auditing or seeding is impossible, rotate).
- Domain split: the private development compose files run with
  `--fake-signing` (throwaway dev keys, persistence irrelevant); this repo's
  production Compose files (`compose.yaml` with `compose.production.yaml`)
  sign for real and rely on the persistence described here, and so does
  `compose.development.yaml`, which never adds `--fake-signing`.

---

## Step 2 — Deploy the stack

### Prerequisites

- Docker + Docker Compose plugin
- The key values from Step 1

### Compose files

| File | Use |
|------|-----|
| `compose.yaml` | Base file with every service; always combined with one overlay below |
| `compose.production.yaml` | Overlay that runs the pre-built images from ghcr.io |
| `compose.development.yaml` | Overlay that builds the images from local source checkouts (`SEAD_SOURCE_DIR`, `SEAD_GATEWAY_SOURCE_DIR`), logs at debug level and publishes the gRPC ports on `127.0.0.1`; it signs with real XMSS keys like production |
| `compose.relay.yaml` | Standalone file for a relay-only bootstrap peer (gossip-node alone) |

All of them set the project name `stardome-sead`, so the `stardome-sead_sead_data`
volume, and with it the XMSS key indices in `edge.db`, carry over from earlier
deployments. `.env.example` sets `COMPOSE_FILE=compose.yaml:compose.production.yaml`,
so with it copied to `.env` a plain `docker compose up -d` in the clone uses the
production pair. With a required variable (marked **†** in the
[configuration reference](#configuration-reference)) unset or empty, every
`docker compose` command stops before starting anything and names it.

### Configure

Write edge-service's three key files as [Key files](#key-files) describes,
then create a `.env` file with your IDs, the key files' paths and the other
values:

```bash
cat > .env << EOF
EDGE_ORG_ID=<org_id_hex>
EDGE_ID=<edge_id_hex>
# Paths to the key files, absolute or relative to the clone
EDGE_SIGNING_KEY_FILE=./keys/edge_signing_key.hex
EDGE_ORG_SIGNING_KEY_FILE=./keys/org_signing_key.hex
EDGE_ORG_PUBLIC_KEY_FILE=./keys/org_public_key.hex
# Gateway auth (required in production — see the gateway README)
SEAD_AUTH_SECRET=<shared-secret>
# gossip-node (C2 sync observer): this node's own org + orgs it observes.
GOSSIP_ORG_ID=<org_id_hex>            # same value as EDGE_ORG_ID
GOSSIP_OBSERVE_ORGS=<other_org_id_hex>,<another_org_id_hex>
GOSSIP_BOOTSTRAP=/ip4/<peer-ip>/tcp/31002/p2p/<peerid>
# This node's reachable multiaddr (required)
GOSSIP_ADVERTISE=/ip4/<public_ip>/tcp/31002
EOF
```

### Key files

edge-service reads its three keys from host files that Compose mounts as
secrets under `/run/secrets/` in the container, and gets only their paths on
its command line. No key appears in the container's command, arguments or
environment, so `docker inspect` of edge-service shows none.

| Variable | The file it names holds |
|----------|-------------------------|
| `EDGE_SIGNING_KEY_FILE` | the edge key's `SECRET_KEY` |
| `EDGE_ORG_SIGNING_KEY_FILE` | the org key's `SECRET_KEY` |
| `EDGE_ORG_PUBLIC_KEY_FILE` | the org key's `PUBLIC_KEY` |

- **Bare hex.** Each file holds one key as hex on one line: the value alone,
  without its `SECRET_KEY` or `PUBLIC_KEY` label. A trailing newline is fine.
- **Owner and mode.** edge-service runs as `sead`, uid `100` and gid `101`,
  and must be able to read each file. Each file has mode `0400`. Its owner
  depends on the platform:
  - **Native Docker Engine on Linux** keeps the host file's owner on a
    bind-mounted secret, so each file must be owned by `100:101`:
    `sudo chown 100:101 keys/*.hex && sudo chmod 0400 keys/*.hex`. Only root
    and the container can then read the files. You don't need to read them
    back after writing them. With the files owned by you instead,
    edge-service fails to read them with `EACCES` and exits. With rootless
    Docker or `userns-remap`, the container's uid and gid map to other ids on
    the host: give each file the host ids that `100` and `101` map to.
  - **Docker Desktop** shows a mounted file to the container as owned by the
    container's user, so files owned by the user who runs `docker compose`
    work: `chmod 0400 keys/*.hex`.

  Outside Swarm mode, Compose ignores `uid`, `gid` and `mode` in the long
  `secrets` syntax, with a warning, so set the owner and mode on the host.
- **Location.** Keep the files outside `./secrets/`, which the gateway
  mounts. `.gitignore` ignores `keys/` in the clone.
- **Failure.** With a file unreadable or empty, edge-service exits at start
  without its keys, since Compose no longer passes the inline `--signing-key`,
  `--org-signing-key` and `--org-public-key` flags it would fall back to.

> **Known gap:** the gateway still reads `SEAD_AUTH_SECRET`,
> `GATEWAY_EDGE_TOKENS` and `GATEWAY_PEER_TOKEN` from environment variables,
> so anyone who can run `docker inspect` on the gateway container can read
> them. Restrict access to the Docker daemon on the host until the gateway can
> read them from files.

> **The org signing key on the host is a deliberate risk.** edge-service signs
> pin and auth tokens with the org secret key, so every edge host of an org
> holds it, and anyone who takes it from one host can sign as the org. Three
> mitigations limit the risk:
>
> - **Few trusted edges per org.** Give an org's key only to the few hosts you
>   trust as much as the org itself.
> - **The persisted token index.** edge-service persists the org key's signer
>   state in `edge.db` after every signature, so a restart never reuses a leaf
>   (see [XMSS key state persistence](#xmss-key-state-persistence-org-and-edge-keys)).
> - **Org key rotation.** When a host that holds the key is lost or exposed,
>   rotate the org key as [docs/org-key-rotation.md](docs/org-key-rotation.md)
>   describes.

> **Key env for the gossip sync** — `GOSSIP_ORG_ID` configures the
> `gossip-node` C2 observer (its own org, always observed). `GOSSIP_OBSERVE_ORGS`
> enables cross-node sync: the node subscribes to each listed org's
> `sead-sync/{org}` topic and publishes frontiers for it. Observation is
> **unilateral** — no publisher consent needed, so each node simply lists the
> orgs it wants to verify for. `GOSSIP_BOOTSTRAP` lists the other nodes'
> libp2p multiaddrs (`/ip4/<ip>/tcp/31002/p2p/<peerid>`); mDNS/DHT also
> auto-discover peers on the same subnet. On **Internet-facing** edges also set
> `GOSSIP_ADVERTISE=/ip4/<public_ip>/tcp/31002` — without it the node advertises its
> container IP and every peer dial fails ("no good addresses" / "dial to self") — and
> keep `GOSSIP_IDENTITY_KEY_FILE` **inside** the mounted volume dir
> (`/data/gossip-keys/gossip-identity.key`); a path outside it regenerates the PeerId
> on every container recreate and invalidates every published bootstrap multiaddr.

> **How a node finds the orgs it observes — four layers.** SEPARATE **networking** from
> **SEAD authority**. There are four distinct layers; the first two are transport, the last
> two are SEAD accountability. Do not conflate them:
>
> 1. **Reachability** — "Can I reach *any* SEAD participant?" Mechanisms: a direct IP,
>    a static peer, DNS, a relay/rendezvous point, or mDNS. This is purely networking; it
>    carries no organization meaning.
> 2. **Bootstrap** — "Can I enter the mesh?" Mechanisms: a bootstrap peer
>    (`GOSSIP_BOOTSTRAP`), a DHT server, or a relay-only node. Still purely networking.
> 3. **Catalog** — "Which nodes legitimately represent Org X?" Answer: the organization's
>    **replication endpoint catalog** — an org-signed DAG event
>    (`replication_endpoint_catalog`, event_type 60) that each org publishes to assert its
>    own replication nodes. SEAD authority begins here.
> 4. **Membership** — "Can those nodes be trusted as Org X?" Answer: the DAG — org genesis,
>    edge authorization, and the catalog's own signature chain. SEAD authority.
>
> **The catalog is authoritative for membership discovery but is NOT a first-contact
> mechanism.** It cannot bootstrap from zero knowledge. A participant must first obtain
> connectivity to *at least one* reachable SEAD node through a transport-level mechanism
> (static bootstrap, DNS, mDNS, DHT, rendezvous, or relay); only *then* can it retrieve the
> organization catalogs and resolve authorized replication membership. **Bootstrap
> establishes connectivity; catalogs establish authority.**
>
> - **To be discoverable**, an org's operator must publish a catalog listing their nodes
>   (node_id + reachable addresses). This is an org decision, like authorizing an edge — it
>   is never inferred from the mesh.
> - **To bootstrap**, a node only needs *one* reachable peer (`GOSSIP_BOOTSTRAP`, mDNS, DHT,
>   relay, rendezvous, or static config) to reach the mesh, then it can retrieve the observed
>   orgs' catalogs and frontiers.
> - The bootstrap peer can be shared out-of-band by any means (IP, DNS, a partner's node) — it
>   does **not** have to be published in the SEAD DAG. The **catalog** is what makes an org's
>   nodes *authoritatively* discoverable.
> - **Which transport to use is up to you.** Choose the reachability/bootstrap mechanism best
>   suited to your deployment: a relay or rendezvous point for roaming or NAT-trapped agents,
>   DNS records as a public entry point, static seeds among nodes you operate, mDNS on a
>   trusted LAN, or plain direct IP. **None of these transport choices confer or require org
>   trust — catalogs do.**
> - A relay or rendezvous point only provides layers 1–2. It is a safe, purely-transport
>   entry that relays no org content and cannot forge org-signed events; it may only affect
>   availability (relaying or withholding gossip), never integrity.
> - **Bootstrap vs. catalog membership is an integrator decision.** A node you share as an
>   entry point is a value you **MAY** let a partner organization use for bootstrapping — it
>   is **not** assumed to be part of the catalog set and publish flow. It may or may not be,
>   depending on your choice: you can keep a **static bootstrap node** and update the
>   frontier-dispatching nodes over time via catalogs, or use the same node(s) for both. The
>   two roles are independent.
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

### Container hardening

`compose.production.yaml` hardens every service:

- `cap_drop: [ALL]`, with no capability added back;
- `security_opt: [no-new-privileges:true]`;
- `read_only: true`, with a `tmpfs` on `/tmp`, and on `/run` for gossip-node
  and the gateway. edge-service gets no `/run` tmpfs, since Compose mounts its
  key files under `/run/secrets/`.

Each service writes only to its volumes. SQLite's `-wal` and `-shm` files stay
next to their databases in the `sead_data` volume, never on a `tmpfs`, so a
recreate keeps every committed write.

It also limits every service's resources:

- `mem_limit: 256m`, and `512m` on edge-service;
- `cpus: "0.5"`;
- `pids_limit: 256`.

The limits are sized for 1-vCPU, 2 GiB hosts. They are per-service ceilings,
not reservations: together they add up to 1.75 GiB of memory and 3 CPUs,
against measured peaks of at most 32 MiB and 12% of a core per service under a
sustained ingest, commit and pin burst. On larger hosts, raise them in
proportion.

Exceptions:

- **gossip-node and the gateway run as root.** sead-core, edge-service and
  source-data-service run as `sead`, and pin-service is pinned to `100:101`
  (the same uid/gid): its image has no `USER`, and with all capabilities
  dropped even root can't bypass file permissions — pin-service writes its
  CID-tracker DB into the `sead_data` volume, owned `100:101`. Without
  capabilities, root in the remaining containers can't bypass file
  permissions either. gossip-node has no `user:` override: it writes its
  identity key into the root-owned directory mounted at `/data/gossip-keys`,
  and as another user it couldn't, so its PeerId would change on every
  recreate.
- **On an existing deployment, `chown 100:101 /data/pin-service.db*` once**
  before first start under this overlay: volumes created by older stacks may
  hold a root-owned pin-service DB that uid 100 can't write.
- **The gateway's image has no `USER`, so it runs as root.** It reads its TLS
  key, `server.key` at mode `0600`, from `./secrets`, mounted read-only at
  `/etc/gateway/certs`, and writes no files. Because capabilities are dropped,
  root here obeys file permissions like any user: `server.key` must be owned
  by (or readable by) root — a key owned by an unprivileged user at `0600`
  makes the gateway crash-loop with `permission denied`.
- **edge-service gets a larger memory limit than the other services.** An
  out-of-memory kill between an XMSS signature and the event's post spends a
  key index without using it, so edge-service gets 512 MiB rather than
  256 MiB.

### Start

Start the stack:

```bash
docker compose -f compose.yaml -f compose.production.yaml pull
docker compose -f compose.yaml -f compose.production.yaml up -d

# Verify the gateway is up (TLS on by default; -k for self-signed)
curl -k https://localhost:30080/health
```

> **On a fresh node (or after `down -v`) `edge-service` exits at startup —
> expected.** `edge-service` fails-fast until its `edge_authorization` is
> resolvable in sead-core, so it won't emit commits with empty
> `dependency_refs[94]`. Enrollment (POST org-genesis / edge-authorization)
> goes through the **gateway → sead-core** path and does not need edge-service,
> so the gateway does not wait on it. `/health` will show `3 healthy /
> 1 unhealthy` (edge-service) until you enroll — follow [Step 3](#step-3--bootstrap-genesis)
> and it will be brought up at the end.
>
> After the org is enrolled, `edge-service` resolves its authorization from
> sead-core at startup, so ordinary `up -d` / `down` cycles work normally.

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
| `EDGE_SIGNING_KEY_FILE` | edge-service | **†** | — | Host path of the file holding the edge XMSS secret key (bare hex); see [Key files](#key-files) |
| `EDGE_ORG_SIGNING_KEY_FILE` | edge-service | **†** | — | Host path of the file holding the org XMSS secret key, which signs auth tokens (bare hex) |
| `EDGE_ORG_PUBLIC_KEY_FILE` | edge-service | **†** | — | Host path of the file holding the org XMSS public key (bare hex) |
| `EDGE_TOKEN_TTL` | edge-service | No | `300` | Auth token TTL in seconds |
| `EDGE_STORAGE_GATEWAY_URL` | edge-service | No | `storage-gateway:50052` | Storage gateway gRPC target |
| `EDGE_PIN_SERVICE_URL` | edge-service | No | `pin-service:50056` | Pin service gRPC target — replaces the storage-gateway IPFS pin leg; edge pins via the Go pin service (`sead_rpc.Storage`) |
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
| `GOSSIP_ADVERTISE` | gossip-node, relay | **†** | — | Multiaddr this node advertises to peers (`/ip4/<public_ip>/tcp/31002`). Without it the node advertises its container IP and every peer dial fails ("no good addresses" / "dial to self") |
| `GOSSIP_IDENTITY_KEY_FILE` | gossip-node | No | `/data/gossip-keys/gossip-identity.key` | Persistent libp2p identity key path. Must be **inside** the mounted `gossip_data` volume dir — a path outside it is not persisted, so the PeerId is regenerated on every recreate and published bootstrap multiaddrs go stale ("peer id mismatch") |
| `GOSSIP_LISTEN` | gossip-node | No | `/ip4/0.0.0.0/tcp/31002` | gossip-node libp2p listen multiaddr |
| `GOSSIP_HEARTBEAT_SEC` | gossip-node | No | `10` | Frontier publish interval (seconds) |
| `GOSSIP_CORE` | gossip-node | No | `sead-core:50051` | Local sead-core gRPC target |
| `GOSSIP_GATEWAY` | gossip-node | No | `gateway:50054` | Local gateway Sync gRPC target |
| `GOSSIP_MDNS` | gossip-node | No | `true` | Enable mDNS LAN peer discovery |
| `GOSSIP_DHT` | gossip-node | No | `true` | Enable Kademlia DHT peer discovery |
| `GOSSIP_PNET` | gossip-node | No | `false` | Enable private-network enforcement |
| `SEAD_AUTH_SECRET` | gateway | **†** | — | Shared secret the gateway requires as `Authorization: Bearer <value>` on its public HTTPS endpoints. It guards the gateway's **public** API (the gRPC calls between the internal C++ services and `gossip-node` do **not** use it). The gateway itself treats an empty value as "auth disabled" (any request accepted with no token), but these Compose files reject an empty value, so a node never starts with auth off by mistake; any **non-empty** value becomes a hard, single accepted Bearer (not "any string"). Generate it with e.g. `openssl rand -hex 32` |
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

**†** Required: the Compose files read it as `${VAR:?}`, so with it unset or
empty `docker compose` exits non-zero naming it. `.env.example` holds example
values for these only so that `docker compose config` resolves; replace them.

> **Gateway config:** the full gateway configuration (TLS, auth, timeouts,
> gRPC targets) is documented in the
> [stardome-sead-gateway](https://github.com/Stardome-technology/stardome-sead-gateway)
> README. The gateway is the single public surface; the C++ services are
> gRPC-only and publish no public HTTP ports.

---

## Step 3 — Bootstrap genesis

> This section is for a **fresh/blank node** (or a **renewal** when a bounded
> `not_after` closes — same procedure, done before the new window is needed).
> Follow it top to bottom. The stack is already up from [Step 2 / Start](#start).

Before the DAG accepts events, register your organization and authorize
your edge. The easiest way is using the `gen-bootstrap` tool, which
builds and signs the CBOR envelopes for you.

> **⚠️ Pass `--key-index-db` on every `gen-bootstrap` signing command for one
> org key.** XMSS is one-time: `org-genesis` and `edge-authorization` are two
> signatures under the same org key and **must** use distinct leaf indices.
> Point every signing command (`org-genesis`, `edge-authorization`,
> `org-key-revoke`) at the **same** `--key-index-db /data/org-key-index.db`
> file (inside a mounted directory) and run them **serialized** — the store
> advances the leaf index across runs (0, 1, …). Running the commands without
> a shared store signs both at leaf 0 and **permanently compromises the org
> key** (WOTS+ leaf reuse). After enrolling, seed that DB into the edge as its
> initial `edge.db` — see
> [docs/bootstrap-genesis.md — Seed the org key index](docs/bootstrap-genesis.md#seed-the-org-key-index-into-edge-service-bootstrap--seed--first-start).

### 3a — Generate the module endorsement signature

The OrgGenesis event requires a **module endorsement signature**: an XMSS
signature produced by the Stardome hardware module (SGE/SSP) over the
CBOR array `[org_id, org_pk, not_before, not_after]`. This proves the
module's XMSS key is installed in a genuine Stardome device.

> **Multiple modules and the org lifecycle.** OrgGenesis accepts **one or
> more** endorsements (k ≥ 1). The enrolled-module set is bound to the *org*
> (any enrolled module may attest for any of the org's edges), it only ever
> **grows** (add modules later via `org_key_revoke` → re-genesis; removal
> requires a new org key), and it is enforced only on the challenge path
> (`/verify`), never at ingest. "Organization" here is a functional unit —
> the smallest logical unit that can exist on the SEAD and spin edges — not
> necessarily a company. See [docs/module-endorsement.md](docs/module-endorsement.md).

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
> **What `not_after` really means (read this).** `not_before`/`not_after` are the
> **overall validity window** of the org key (org-genesis) or edge authorization
> (edge-authorization). They are **NOT** a window within which you must perform a
> single one-off action. While `now` is inside `[not_before, not_after]` the key is
> authorized; **after `not_after` passes, verifiers reject new events from it** (e.g.
> sead-core returns `ERR_EDGE_NOT_AUTHORIZED: no active edge authorization`), and a
> previously-working edge stops committing. Set `not_after = 0` for **no expiry**, or
> pick a comfortably long window (years) for long-lived deployments. A bounded
> `not_after` means the org/edge must be **re-enrolled** (regenerate + re-post
> org-genesis / edge-authorization) once the window closes.
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

Confirm the stack is up and note the baseline health — on a fresh node
`edge-service` is **not** yet running (expected):

```bash
curl -k https://localhost:30080/health
# Expected on a fresh node: total_services=4, healthy=3, unhealthy=1
# (unhealthy = edge-service, which starts only after 3c enrolls the edge).
```

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
  --not-after <unix_epoch_sec> \
  --key-index-db /data/org-key-index.db
```

> **Important:** Docker only sees files inside mounted volumes. The
> `--attestation-file` path must be inside a directory you passed with
> `-v`. If the file is elsewhere, mount that directory instead:
> `docker run --rm -v /absolute/path/to/signatures:/data ...`

The `--attestation-file` option extracts the module's public key, Merkle root,
and XMSS signature from the attestation CBOR binary, and derives the
`module_id` as `SHAKE256(module_pk)` automatically.

> **Multiple modules in one genesis:** `--attestation-file` is **repeatable** —
> pass one file per module (each produced by `stardome-client endorse` with
> the **same** `--org-id/--org-pk/--not-before/--not-after`) and the genesis
> enrolls all of them. Duplicate modules are rejected before signing. Example:
> add `--attestation-file /data/endorse_att_m2.bin` to the command above.
> See [docs/module-endorsement.md](docs/module-endorsement.md#tooling-note).

Alternatively, you can pass individual module arguments (legacy):

```bash
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --module-id <module_id_hex> \
  --module-pk <module_pk_hex> \
  --module-merkle-root <merkle_root_hex> \
  --module-signature <sig_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --key-index-db /data/org-key-index.db
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
  --key-index-db /data/org-key-index.db \
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

> **Capture the org-genesis event_id (needed in 3c).** The POST response
> returns the org_genesis `event_id` (a 64-hex string). Save it — the
> `edge-authorization` command in step 3c must pass it as
> `--genesis-event-id`. Example:
> ```bash
> # response: {"event_id":"<64-hex>","event_type":1,"event_type_name":"org_genesis","status":"accepted"}
> GENESIS_EVENT_ID=<64-hex>
> ```

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
# The 64-hex org_genesis event_id captured in step 3b:
GENESIS_EVENT_ID=<org_genesis_event_id_64hex>

docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --genesis-event-id "$GENESIS_EVENT_ID" \
  --edge-id <edge_id_hex> \
  --edge-pk <edge_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --key-index-db /data/org-key-index.db \
  --out-file /data/envelope.hex
```

> `--genesis-event-id` is **required**: it is written into the
> edge-authorization's `dependency_refs` (field 94), pointing at the
> `org_genesis` from step 3b. sead-core resolves the authorization against
> that specific genesis (content-addressed authority resolution) and rejects
> an `edge_authorization` with no such reference (`ERR_MISSING_DEPENDENCY`).
> If the referenced genesis isn't present yet, sead-core holds the
> authorization pending and promotes it once the genesis lands.

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

### 3d — Bring up edge-service

The org and edge are now enrolled. **Before the first start, seed the org key
index**: copy the `org-key-index.db` produced in 3b/3c to the edge's data
volume as its initial `edge.db` (fresh edge — plain `cp`; merge into an
existing `edge.db` via `edge-index-audit --seed`). The org signer then
resumes at leaf ≥ 2 instead of reusing the bootstrap leaves. In the merge case
`--seed` applies only to the **edge** key's own row (it derives the index from
`edge_commit` events in `sead.db`) and by default refuses to alter an existing
`key_index` row. Full procedure:
[docs/bootstrap-genesis.md — Seed the org key index](docs/bootstrap-genesis.md#seed-the-org-key-index-into-edge-service-bootstrap--seed--first-start).

Start `edge-service` (it auto-resolves the
`edge_authorization` event_id from sead-core at startup) and confirm the whole
stack is healthy:

```bash
docker compose -f compose.yaml -f compose.production.yaml up -d edge-service

# Expect 4/4 healthy (edge-service now ok)
curl -k https://localhost:30080/health
```

Enrollment is complete. From here ordinary `up -d` / `down` cycles work
normally.

### Key rotation and revocation

To retire a compromised or rotated org key, post an `org_key_revoke` event
(event_type 2). The envelope is **generated** with the `gen-bootstrap` tool
(`org-key-revoke` subcommand, signed with the current active org key on a
secure offline laptop) and then **POSTed** to `/events` — full procedure,
flags table, and the two rotation orderings (new `org_id`: genesis-then-revoke;
same `org_id`: revoke-then-genesis) are in
[docs/bootstrap-genesis.md — Key revocation](docs/bootstrap-genesis.md#key-revocation).

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

> **`payload_hash` is SHAKE256-256** (64 hex chars) of the raw artifact bytes —
> the same digest as the DAG `payload_hash` (`edge_commit` body key 3) and the
> auth-token `payload_hash` field (key 8). It is echoed from the pin service,
> which keys its CID tracker by exactly this value, so it is always resolvable
> via `GET /cid/{payload_hash}`. Do **not** substitute a SHA-256 of the
> artifact: hardware-attestation internals are SHA-256, but the DAG/pin key is
> SHAKE256 (see `docs/13-sead-identity-and-hash-map.md` §5).

Retrieve a pinned artifact by its payload hash:

```bash
# CURL_TLS: "-k" for self-signed/isolated, "" or "--cacert <ca.crt>" for public/private CA
curl $CURL_TLS https://localhost:30080/cid/<payload_hash_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
```

> **Token minting:** the edge-service auto-generates per-pin auth tokens
> internally (signed by the org XMSS key) when it commits an artifact and
> pins it to IPFS via the Go pin service (`sead_rpc.Storage`) over gRPC.
> The standalone `POST /auth/token` HTTP endpoint on edge-service is
> **removed** in the Go Gateway migration — edge-service is gRPC-only.
> For the IPFS auth stack deployment (minimal sead-core + gateway), see
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

## Git workflow

This repository follows GitHub Flow (https://docs.github.com/en/get-started/using-github/github-flow).
The authoritative rules for contributors and agents are in the `## Git workflow`
section of [AGENTS.md](AGENTS.md).
