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
        subgraph "SEAD stack (sead-network)"
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

## 2. Ports to open on the VPS firewall

> These are the **host** ports that must be reachable from outside. The
> internal gRPC ports (`50051`–`50055`) stay private to the Docker network
> and are **not** exposed directly.

| Port | Transport | Service | Who needs it |
|---|---|---|---|
| **80** | TCP | nginx (HTTP → HTTPS redirect) | everyone |
| **443** | TCP | nginx (TLS: Explorer UI + API + gateway proxy) | everyone |
| **30080** | TCP | gateway HTTPS API (cross-org event fetch, ingest, verify) | other SEAD nodes, brokers |
| **31002** | TCP | gossip-node libp2p peer (frontier dissemination + event fetch) | other SEAD nodes |

**Not exposed** (private to the Docker network): `50051` (sead-core),
`50052` (storage-gateway), `50053` (source-data-service), `50054` (gateway
Sync gRPC), `50055` (edge-service), `8086` (Explorer API — reachable only via
nginx `/api`), `3000` (Explorer UI — reachable only via nginx `/`).

### Firewall example (UFW)

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 30080/tcp
sudo ufw allow 31002/tcp
sudo ufw enable
```

> **Hardening (recommended):** `31002` (gossip-node libp2p) only needs
> to be reachable by *other SEAD nodes*. If you know their IPs, restrict it
> to those peers instead of opening it to the whole internet:
> `sudo ufw allow from <peer-ip> to any port 31002 proto tcp`, etc.

---

## 3. Deploy the SEAD stack

Follow the standard deployment in the main [`README.md`](../README.md)
(keys, bootstrap genesis, edge authorization). The only differences for a VPS:

### 3.1 `.env` for the stack

```bash
EDGE_ORG_ID=<org_id_hex>
EDGE_ID=<edge_id_hex>
EDGE_SIGNING_KEY=<edge_secret_key_hex>
EDGE_ORG_SIGNING_KEY=<org_secret_key_hex>
EDGE_ORG_PUBLIC_KEY=<org_public_key_hex>
GOSSIP_ORG_ID=<org_id_hex>            # same value as EDGE_ORG_ID
GOSSIP_OBSERVE_ORGS=<other_org_id_hex>,<another_org_id_hex>
GOSSIP_BOOTSTRAP=/ip4/<peer-ip>/tcp/31002/p2p/<peerid>
SEAD_AUTH_SECRET=<shared-secret>         # required in production
```

> **`GOSSIP_BOOTSTRAP`** lists the other nodes' libp2p multiaddrs
> (`/ip4/<ip>/tcp/31002/p2p/<peerid>`); mDNS/DHT also auto-discover peers on
> the same subnet. `GOSSIP_OBSERVE_ORGS` enables cross-node sync (the node
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
docker compose -f docker-compose.remote.yml pull
docker compose -f docker-compose.remote.yml up -d

# Verify the gateway is healthy
curl -k https://localhost:30080/health
```

---

## 4. Deploy the Explorer

Deploy the Explorer on the same VPS (see
[stardome-sead-explorer](https://github.com/Stardome-technology/stardome-sead-explorer)).

```bash
docker network create sead-network 2>/dev/null || true
docker compose -f docker-compose.remote.yml pull
docker compose -f docker-compose.remote.yml up -d

curl http://127.0.0.1:8086/health
curl http://127.0.0.1:3000/
```

Because the Explorer runs on the **same VPS** as the stack, its `.env` uses the
internal Docker-network URLs (via the gateway):

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

`gossip-node` is included in the SEAD stack compose (`docker-compose.remote.yml`)
and starts automatically. It runs its own libp2p peer on `31002` and
publishes/subscribes frontiers on `sead-sync/{org}` topics.

For other SEAD nodes to reach this VPS node across subnets, configure them with
this VPS as a bootstrap peer:

```bash
# On the OTHER nodes' .env — replace <VPS-IP> and <PEER_ID> with real values
GOSSIP_BOOTSTRAP=/ip4/<VPS-IP>/tcp/31002/p2p/<PEER_ID>
```

Get `<PEER_ID>` from this VPS node's gossip-node logs (it prints its peer ID
at startup).

---

## 6. Nginx reverse proxy

Nginx terminates TLS on `443` and routes:

- `/` → Explorer UI (nginx container on `3000`)
- `/api` → Explorer API (FastAPI on `8086`)
- `/ingest`, `/auth/verify` → gateway (`30080`) — **for remote brokers**
- `/health` → gateway health (optional)

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
