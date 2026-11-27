# Remote VPS Deployment — SEAD Stack + Explorer

This guide covers the **remote VPS** deployment topology, where the full SEAD
stack (gateway, edge-service, storage-gateway, source-data-service, sead-core,
gossip-node), the **Explorer** (UI + API), and the **gateway** all run on a
single remote VPS.

> **Go Gateway migration (phase 4.4):** the C++ services are **gRPC-only** and
> publish no public HTTP ports. The **gateway** is the single public HTTPS
> entry point. `auth-service` and `verifier-service` are collapsed into the
> gateway (no longer standalone services).

This differs from a single-host deployment which assumes
the **broker running on the same device** as the stack and talking to the gateway
over `host.docker.internal:30080`. Here the broker still mimics the integrator firmware
and reaches the VPS gateway over the network as in real world deployments.

```mermaid
graph TB
    subgraph "Remote VPS"
        subgraph "SEAD stack (public and backend networks)"
            GW[gateway :30080]
            SC[sead-core :50051 gRPC]
            ES[edge-service :50055 gRPC]
            SG[storage-gateway :50052 gRPC]
            SD[source-data-service :50053 gRPC]
            GN[gossip-node :31002 libp2p]
        end
        subgraph "Explorer"
            UI[Explorer UI nginx :80]
            API[Explorer API :8086]
            DB[(PostgreSQL)]
        end
        NGINX[nginx :443]
    end

    subgraph "Remote clients"
        BR[Local broker / integrator firmware]
        OTH[Other SEAD edge nodes]
        BROWSER[Browser]
    end

    BR -->|"POST /ingest, /auth/verify"| NGINX
    NGINX -->|proxy| GW
    BROWSER -->|"https://edge.example.com/"| NGINX
    NGINX -->|proxy /api| API
    API -->|internal| GW
    OTH -->|"31002 tcp"| GN
    GN -->|"gRPC SyncFetch"| GW
```

---

## 1. Single-host deployment vs remote VPS

| Concern | Single-host (co-located) | Remote VPS (this guide) |
|---|---|---|
| Broker → edge | `https://host.docker.internal:30080` (gateway, same host) | `https://edge.example.com` (via nginx) |
| Edge-service exposure | Private Docker network only | Public via nginx (TLS) |
| Explorer UI | `http://localhost:3000` | `https://edge.example.com/` |
| Explorer API | `http://localhost:8086` | `https://edge.example.com/api` (optional) |
| gossip-node libp2p | LAN/mesh IP | VPS public IP |

---

## 2. Network exposure

The Compose files ship a secure reference configuration. You own your node's
configuration and operation: this section describes the reference, and the
invariants to keep when you change it.

### 2.1 Reference configuration

- **The gateway terminates TLS itself on `30080`**, with its certificate and
  key mounted read-only from `./secrets` at `/etc/gateway/certs`. The Compose
  files add no TLS front.
- **Only `30080` (gateway) and `31002` (gossip-node) are published**, on all
  interfaces. Every other port stays inside Docker.
- **Two networks.** `backend` is internal: Docker gives it no route out of the
  host. sead-core, edge-service and source-data-service are on `backend` alone.
  The services that connect out, or that are reached from outside, are on
  `public` as well:

  | Service | Networks | Why it's on `public` |
  |---|---|---|
  | sead-core, edge-service, source-data-service | `backend` | — |
  | pin-service | `backend`, `public` | connects out to the IPFS API |
  | gateway | `backend`, `public` | serves `30080`, and fetches from the peer gateways in `GATEWAY_PEERS` |
  | gossip-node | `backend`, `public` | serves and dials libp2p peers on `31002` |

  `public` keeps the Docker name `sead-network`, so a Compose project that
  attaches to `sead-network` as an external network, such as the Explorer in
  [section 4](#4-deploy-the-explorer), still reaches the gateway by name. It
  reaches nothing on `backend`.
- **Production settings**, set as literal values in `compose.production.yaml`,
  not read from `.env`:
  - `GOSSIP_MDNS=false`: mDNS is link-local multicast, so on a Docker bridge it
    finds no peer across the Internet; peers come from `GOSSIP_BOOTSTRAP`.
  - `GOSSIP_DHT=true`: the DHT bootstraps only from `GOSSIP_BOOTSTRAP`, so it
    discovers peers within the SEAD mesh, not on the public IPFS DHT.
  - `GATEWAY_PEER_TLS_INSECURE=false`: the gateway verifies its peer gateways'
    certificates. Use public certificates, or set `GATEWAY_PEER_CA_CERT` to a
    PEM CA bundle for peers on a private CA.

  `compose.development.yaml` turns mDNS on, lets the gateway accept self-signed
  peer certificates, and makes `backend` non-internal so the gRPC ports it
  publishes on `127.0.0.1` reach the services.

CI checks the resolved production config and fails unless the published ports
are exactly `30080` and `31002`, no port binds `127.0.0.1`, `backend` is
`internal: true`, and the three settings above hold.

### 2.2 Who reaches which port

| Port | Transport | Service | Who reaches it |
|---|---|---|---|
| **30080** | TCP, HTTPS | gateway API (event fetch, ingest, verify, health) | edge clients, brokers, explorers, and the federation peers that list this node in their `GATEWAY_PEERS` |
| **31002** | TCP, libp2p | gossip-node (frontier dissemination, event fetch) | the other gossip-nodes of your own stack, and your federation partners' |
| **80**, **443** | TCP | nginx, only if you run the proxy of [section 6](#6-nginx-reverse-proxy) | everyone |

**Not exposed** (inside Docker): `50051` (sead-core), `50053`
(source-data-service), `50054` (gateway Sync gRPC), `50055` (edge-service),
`50056` (pin-service), and the Explorer's `8086` and `3000`, reached only
through nginx.

### 2.3 Exposure postures

- **Open to all, with gateway authentication: supported.** This is the
  reference. Every endpoint on `30080` except `/health` requires the gateway's
  authentication (`SEAD_AUTH_SECRET`, edge tokens or CBOR auth tokens), and
  gossip-node accepts libp2p connections from anyone, while which nodes may
  act for an org is decided by the org's catalog and signatures
  ([section 5.3](#53-who-gives-whom-a-bootstrap-entry)).
- **A host-firewall allow-list: optional hardening.** If you know who reaches
  each port, allow only them: for example, `31002` only from your federation
  partners' nodes. Compose can't filter by source address, so this is the
  host's job.

> **Docker bypasses UFW for published ports.** Docker writes its own iptables
> rules for `30080` and `31002`, which traffic reaches before UFW's `INPUT`
> rules. `ufw deny` or `ufw allow from` therefore don't restrict them: filter
> in the `DOCKER-USER` chain, or in your cloud provider's firewall.

For the reference posture, open the ports in the cloud security group, and in
UFW if the host runs it:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 30080/tcp
sudo ufw allow 31002/tcp
sudo ufw enable
```

### 2.4 Behind a reverse proxy

You may put a reverse proxy in front of the gateway, such as the nginx of
[section 6](#6-nginx-reverse-proxy). It is your variant, not part of the
reference, and it must keep two invariants:

1. **The gateway port is reachable only through the proxy.** Clients that
   reached `30080` reach the proxy instead, and the host stops `30080` from
   outside, in the `DOCKER-USER` chain or the cloud firewall, or by binding it
   to `127.0.0.1` in a Compose override file of your own. The production
   overlay doesn't bind it there, since the reference serves `30080` directly.
2. **The proxy filters `/metrics`:** it doesn't forward `/metrics` from
   outside, or forwards it only from your monitoring hosts.

`31002` stays exposed directly: it carries raw libp2p TCP, which an HTTP proxy
such as nginx can't forward.

### 2.5 `/metrics`

From gateway `v0.1.0`, the image `compose.production.yaml` pins, `/metrics`
needs a token:

- set `GATEWAY_METRICS_TOKEN`, or `GATEWAY_METRICS_TOKEN_FILE` with a container
  path under `/etc/gateway/certs`, and send it as `Authorization: Bearer
  <token>`; without it, or with a wrong one, `/metrics` answers `401`;
- with gateway authentication on, the default, and no token set, the gateway
  doesn't serve `/metrics` at all: it answers `404` and logs a warning at
  startup;
- `GATEWAY_METRICS_ENABLED=false` removes the route: `404` whatever the token.

The gateway logs its posture at startup as `metrics posture: token-gated`,
`disabled` or `open`.

On the gateway images before `v0.1.0`, `/metrics` answers on `30080` without
authentication, whatever `GATEWAY_METRICS_ENABLED` says. It serves only the Go
runtime and process metrics (`go_*`, `process_*`, `promhttp_*`), no SEAD data,
so what it exposes is the Go version, restarts and traffic volume. A node on
those images that runs a proxy filters `/metrics` there, and since a proxy on
`443` doesn't cover `30080` itself, also stops `30080` from outside, as in
[2.4](#24-behind-a-reverse-proxy).

### 2.6 Upgrade notes

- **`/metrics` loses its `go_*` and `process_*` series from gateway
  `v0.1.0`.** The gateway now serves its own registry, not Go's default one, so
  dashboards and alerts that read those series find nothing: move them to the
  gateway's own metrics.
- **`.env` no longer sets `GOSSIP_MDNS`, `GOSSIP_DHT` or
  `GATEWAY_PEER_TLS_INSECURE`.** The overlays set them, and a value left in
  `.env` has no effect. A node that relied on `GATEWAY_PEER_TLS_INSECURE=true`
  for self-signed peers sets `GATEWAY_PEER_CA_CERT` instead, or gives its peers
  public certificates.
- **The stack moves from one network to two.** Run `docker compose down`, then
  `docker compose up -d`, rather than `up -d` alone, so Compose recreates
  `sead-network` with its new definition; some Compose versions refuse to
  reuse it otherwise. `down` keeps the volumes, as long as you don't pass `-v`.
  Stop any other project attached to `sead-network` first, such as an
  Explorer on the same host, and start it again afterwards.

---

## 3. Deploy the SEAD stack

Follow the standard deployment in the main [`README.md`](../README.md)
(keys, bootstrap genesis, edge authorization). The only differences for a VPS:

### 3.1 `.env` for the stack

```bash
EDGE_ORG_ID=<org_id_hex>
EDGE_ID=<edge_id_hex>
EDGE_SIGNING_KEY_FILE=./keys/edge_signing_key.hex   # bare-hex key files, mode 0400,
EDGE_ORG_SIGNING_KEY_FILE=./keys/org_signing_key.hex # owned by 10001:10001 on Linux:
                                                     # see the README, "Key files"
EDGE_ORG_PUBLIC_KEY_FILE=./keys/org_public_key.hex
GOSSIP_ORG_ID=<org_id_hex>            # same value as EDGE_ORG_ID
GOSSIP_OBSERVE_ORGS=<other_org_id_hex>,<another_org_id_hex>
GOSSIP_BOOTSTRAP=/ip4/<peer-ip>/tcp/31002/p2p/<peerid>
SEAD_AUTH_SECRET=<shared-secret>         # required in production
```

> **`GOSSIP_BOOTSTRAP`** lists the other nodes' libp2p multiaddrs
> (`/ip4/<ip>/tcp/31002/p2p/<peerid>`); the DHT also discovers peers through
> them. mDNS is off in production ([2.1](#21-reference-configuration)). `GOSSIP_OBSERVE_ORGS` enables cross-node sync (the node
> subscribes to each listed org's `sead-sync/{org}` topic).
>
> **Networking vs. authority — four layers.** Reachability and bootstrap are *transport
> only*; catalog and membership are SEAD authority. They must not be conflated:
>
> - **Reachability** — "can I reach any SEAD participant?" (direct IP, static peer, DNS,
>   relay/rendezvous, mDNS). Networking only.
> - **Bootstrap** — "can I enter the mesh?" (`GOSSIP_BOOTSTRAP`, DHT, or a relay-only node).  
>   Networking only; which one you use is up to you.
> - **Catalog** — "which nodes represent org X?" The org-signed
>   `ReplicationEndpointCatalog` (event_type 60). SEAD authority begins here.
> - **Membership** — "can those nodes be trusted as org X?" Org genesis → edge authorization
>    → the catalog's signature chain. SEAD authority.
>
> **The catalog is not a first-contact mechanism** — it cannot bootstrap from zero knowledge.
> A node must first reach *a* SEAD peer via a transport mechanism (bootstrap, DNS, mDNS, DHT,
> rendezvous, or relay), then retrieve the catalogs. **Bootstrap establishes connectivity;
> catalogs establish authority.** Choose the transport that fits your deployment (static
> seed, DNS/relay for roaming/NAT, mDNS on a trusted LAN, or direct IP); none of these confer
> org trust. See the main README for the full model.

### 3.2 Start

```bash
docker compose -f compose.yaml -f compose.production.yaml pull
docker compose -f compose.yaml -f compose.production.yaml up -d

# Verify the gateway is healthy
curl -k https://localhost:30080/health
```

edge-service is in the `edge` profile, so this `up -d` leaves it stopped until
the node is enrolled; enrollment ends by setting `COMPOSE_PROFILES=edge` in
`.env` (see the README, "3d — Bring up edge-service").

---

## 4. Deploy the Explorer

Deploy the Explorer on the same VPS (see
[stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer)).
In the Explorer's clone, pull and start its remote Compose file as its README
describes, then check it:

```bash
docker network create sead-network 2>/dev/null || true
# pull and up -d with the Explorer's own Compose file, from its clone

curl http://127.0.0.1:8086/health
curl http://127.0.0.1:3000/
```

Because the Explorer runs on the **same VPS** as the stack, it attaches to
`sead-network`, the stack's `public` network, and its `.env` reaches the gateway
by name. It can't reach the services on `backend`
([2.1](#21-reference-configuration)):

```bash
SEAD_CORE_URL=http://gateway:30080
EDGE_SERVICE_URL=http://gateway:30080
STORAGE_GATEWAY_URL=http://gateway:30080
DATABASE_URL=postgresql://explorer:explorer@sead-explorer-db:5432/sead_explorer
OBSERVER_ORG_ID=<observer_org_id_hex>
OBSERVER_NODE_ID=<observer_node_id_hex>
```

> The Explorer API (`8086`) and UI (`3000`) are **not** exposed directly. They
> are reached through nginx on `443` (see below). If you want integrators to
> consume the Explorer API, expose it via nginx `/api`; otherwise keep it
> internal.

---

## 5. gossip-node (sync observer)

`gossip-node` is included in the SEAD stack compose (`compose.yaml`)
and starts automatically. It runs its own libp2p peer on `31002` and
publishes/subscribes frontiers on `sead-sync/{org}` topics. `31002` is published on
the host so other nodes can dial this peer.

### 5.1 The `GOSSIP_BOOTSTRAP` multiaddr format

`GOSSIP_BOOTSTRAP` is a comma-separated list of **libp2p multiaddrs** telling a node which
peer(s) to dial to enter the mesh. Each entry has the form
`/ip4/<ip>/tcp/31002/p2p/<peerid>`, but the network component is **not limited to an IP** —
libp2p multiaddrs also support DNS:

```bash
# IP (LAN / mesh / VPS):
/ip4/192.168.50.104/tcp/31002/p2p/<peerid>
/ip4/<VPS-IP>/tcp/31002/p2p/<peerid>

# DNS (works when an address record or path resolves the host):
/dns4/sead.example.org/tcp/31002/p2p/<peerid>
/dnsaddr/sead.example.org/tcp/31002/p2p/<peerid>
```

The peer dialed this way becomes a **transport-level entry point** (layer 1–2) — it has no
org meaning by itself. The DHT also discovers peers once the node is connected, and in
development mDNS finds peers on the same subnet; `GOSSIP_BOOTSTRAP` is the deterministic
static-seed path. Once connected, the node
retrieves the observed orgs' catalogs over the mesh.

### 5.2 Getting `<PEERID>`

Each `gossip-node` prints its stable (persistent-identity) peer ID at startup:

```bash
docker logs stardome-sead-gossip-node-1 | grep "peer ID"
# → [gossip-node] libp2p node started, peer ID: 12D3KooW...
```

The peer ID is stable across restarts (backed by `/data/gossip-keys/gossip-identity.key`), so you capture
it **once** and reuse it in other nodes' `GOSSIP_BOOTSTRAP`. You will need the IP or hostname
of the peer *and* its peer ID to build the entry.

> ⚠️ **Do NOT let the identity key location change.** The key is a host bind-mount
> (`GOSSIP_IDENTITY_DIR`, default `/var/lib/sead/gossip-keys`). If `GOSSIP_IDENTITY_DIR`
> points at a different host path, such as one under `~`, which changes with the user who
> runs `docker compose` (`sudo` sets `HOME=/root`), `gossip-node` finds no existing key
> there, generates a **new** one, and the PeerID **rotates**. Every other node
> that hardcoded the old PeerID in `GOSSIP_BOOTSTRAP` then fails to connect with
> `peer id mismatch: expected … but remote key matches …`, and the mesh silently stops sharing
> frontiers (`topic peers=0`, "no catalog in DAG state").
>
> To avoid this: keep `GOSSIP_IDENTITY_DIR` an **absolute** path, and copy an existing key
> there once, as [README — Gossip identity key](../README.md#gossip-identity-key)
> describes. If a PeerID ever does rotate, update the
> affected `GOSSIP_BOOTSTRAP` entries to the new PeerID (`docker logs <gossip> | grep "peer ID"`).
> The wipe/provision flow (`compose down -v`, re-enrollment) does **not** touch this key — it
> survives, as intended.

### 5.3 Who gives whom a bootstrap entry

A `GOSSIP_BOOTSTRAP` entry is something you **issue to a peer**, not a claim about org
membership. Two common cases:

- **A third-party integrator bootstrapping onto your org's nodes.** You give the integrator a
  multiaddr pointing at *one of your reachable SEAD nodes* (`/ip4/<your-ip>/tcp/31002/p2p/
  <your-peerid>`). That integrator dials it to contact the mesh and then retrieves *your* org's
  catalogs to learn which of your nodes legitimately represent the org. This is a **sharing**
  of a transport entry point — it is not a trust claim about the integrator or your node.
- **Your own org's "supplementary" (additional) nodes bootstrapping onto each other.** If you
  run multiple nodes for the same org, list one another's multiaddrs in `GOSSIP_BOOTSTRAP` so
  they form a direct mesh, and each retrieves the org's catalog to fill in the full node set.

In both cases the entry is **transport only** (layer 1–2). Whether a node may act for an org
is decided by the org's **catalog** and DAG signatures — `ReplicationEndpointCatalog`
(event_type 60) lists the nodes + reachable addresses that legitimately represent the org for
replication — not by the bootstrap list. The same multiaddr can be dialed by a third party
and by your own supplementary nodes; what changes is only *which orgs* each dial.

For example, if this VPS node is one of org A's replication endpoints and has peer ID `12D3KooW...`:

```bash
# On a THIRD-PARTY integrator node observing org A:
GOSSIP_BOOTSTRAP=/ip4/<VPS-IP>/tcp/31002/p2p/12D3KooW...
GOSSIP_OBSERVE_ORGS=<org_A_hex>

# on your OWN supplementary node for org A:
GOSSIP_BOOTSTRAP=/ip4/<VPS-IP>/tcp/31002/p2p/12D3KooW...
GOSSIP_ORG_ID=<org_A_hex>
GOSSIP_OBSERVE_ORGS=<org_A_hex>,<org_B_hex>
```

---

## 6. Nginx reverse proxy

This is the reverse-proxy variant of [2.4](#24-behind-a-reverse-proxy): keep
its two invariants. Nginx terminates TLS on `443` and routes:

- `/` → Explorer UI (nginx container on `3000`)
- `/api` → Explorer API (FastAPI on `8086`)
- `/ingest`, `/auth/verify` → gateway (`30080`) — **for remote brokers**
- `/health` → gateway health (optional)
- `/metrics` → nothing: nginx answers `404`

### 6.1 Install + TLS

```bash
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
sudo certbot --nginx -d edge.example.com
```

### 6.2 Site config

Create `/etc/nginx/sites-available/edge.example.com`:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name edge.example.com;

    ssl_certificate     /etc/letsencrypt/live/edge.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/edge.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # Large artifacts (XMSS signatures are ~18 KB; allow headroom)
    client_max_body_size 10M;

    # ── Explorer UI ────────────────────────────────────────────────────
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ── Explorer API ───────────────────────────────────────────────────
    # Expose the API to integrators. Remove this block to keep it internal.
    location /api/ {
        proxy_pass http://127.0.0.1:8086;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ── Gateway: ingest (remote brokers) ────────────────────────────────
    # Requires a valid org auth token (Bearer header) — verified by the
    # gateway against sead-core.
    location /ingest {
        proxy_pass http://127.0.0.1:30080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
    }

    # ── Gateway: auth verify (remote brokers) ───────────────────────────
    # POST /auth/verify — verifies a CBOR auth token (collapsed from
    # auth-service). The key-index admin endpoints are internal only.
    location = /auth/verify {
        proxy_pass http://127.0.0.1:30080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ── Gateway metrics: never forwarded from outside ───────────────────
    location = /metrics {
        return 404;
    }

    # ── Gateway health (optional, unauthenticated) ──────────────────────
    location = /health {
        proxy_pass http://127.0.0.1:30080/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
}
```

Enable and reload:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/edge.example.com /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

## 7. Point remote brokers at the VPS

The broker reaches the gateway via `SEAD_EDGE_URL`, which is used as a
**base URL** — the broker appends `/ingest` and `/auth/verify` itself.

```bash
# stardome-sead-broker .env
SEAD_EDGE_URL=https://edge.example.com
```

> The `extra_hosts: host.docker.internal` entry in the broker compose is
> harmless but **no longer needed** in remote mode — remove it if you prefer.

### 7.1 How `/ingest` is authenticated

The gateway `/ingest` handler **requires a valid org auth token** on every
request. The caller sends the token as a `Bearer` header:

```
Authorization: Bearer <base64url-encoded CBOR auth token>
```

The gateway:
1. Decodes and parses the token (CBOR).
2. Resolves the org's public key from sead-core and verifies the XMSS signature.
3. Checks expiry, scope (`ipfs_pin`), and (if present) `payload_hash` binding.
4. Enforces the **org boundary** — the token's `org_id` must match the
   `org_id` in the request body.

This means `/ingest` is no longer open to anonymous callers: only a caller
holding a valid token for the target org can submit artifacts. The broker sends
this token automatically (see below).

> **Still recommended:** even with token auth, consider restricting `/ingest`
> by IP (nginx `allow`/`deny` or firewall) to known broker/integrator networks
> as defense-in-depth. The broker is an **example** of how integrators
> implement their firmware; it is the integrator's responsibility to implement
> a secure, well-designed path/token to reach the edge services.

### 7.2 Broker token flow

The broker resolves the token (per-request `auth_token` → `SEAD_AUTH_SECRET`
The broker resolves the token (per-request `auth_token` → `SEAD_AUTH_SECRET`
env var) **before** calling `/ingest`, and sends it as a `Bearer` header. No
code change is needed in the broker `.env` beyond setting `SEAD_AUTH_SECRET`:
code change is needed in the broker `.env` beyond setting `SEAD_AUTH_SECRET`:

```bash
# stardome-sead-broker .env
SEAD_EDGE_URL=https://edge.example.com
SEAD_AUTH_SECRET=<base64url-encoded CBOR auth token>
SEAD_AUTH_SECRET=<base64url-encoded CBOR auth token>
```

> **Note on auto-generation:** because the gateway now requires the token *on*
ingest, the broker's auto-generation fallback (which needs the `payload_hash`
known only *after* ingest) is no longer compatible with an auth-requiring
edge. Use a pre-generated token (`SEAD_AUTH_SECRET` or per-request
> `auth_token`) — the recommended production flow.

---

## 8. Verification checklist

```bash
# Stack
curl -k https://localhost:30080/health

# Explorer (via nginx)
curl -k https://edge.example.com/health
curl -k https://edge.example.com/api/v1/frontier

# Gateway (from a remote broker host) — requires a valid auth token
curl -X POST https://edge.example.com/ingest \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d '{"module_id":"<hex>","org_id":"<hex>","edge_id":"<hex>","artifact":"<hex>"}'

# gossip-node libp2p listening
ss -tulpn | grep 31002
```
