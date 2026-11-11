# Bootstrap Genesis — First Org and Edge Registration

After deploying `sead-core`, you must register an organization and authorize an edge
before the auth stack can verify tokens. This is a one-time operational step.

> **Blank-node boot order (important).** `edge-service` fails-fast (exits) until
> its `edge_authorization` is resolvable in sead-core, and enrollment below is
> served by the gateway → sead-core path (edge-service is **not** required to
> POST these events). The gateway therefore does **not** wait on edge-service.
> On a fresh node (after `down -v` or a new deploy) a full `docker compose up -d`
> leaves **edge-service exited — expected**. Complete Step 1 (org-genesis) and
> Step 2 (edge-authorization) below, seed the key-index DB as the initial
> `edge.db` (see "Seed the org key index into edge-service"), then start it:
> ```bash
> docker compose -f <compose-file> up -d edge-service
> ```
> For ordinary up/down cycles **after** enrollment, the usual full `up -d` works
> normally (edge-service auto-resolves its authorization at startup).

## Prerequisites

- `sead-core` is running and healthy: `curl http://localhost:30080/health`
- You have generated at least one XMSS keypair using the `keygen` tool:
  ```bash
  # Build the keygen tool
  cmake -B build -DBUILD_TOOLS=ON && cmake --build build -j
  
  # Generate an organization keypair (XMSS-SHAKE256_20_256 — DAG signing scheme)
  ./build/tools/keygen --label my-org --oid 0x12
  
  # Generate an edge keypair
  ./build/tools/keygen --label my-edge --oid 0x12
  ```
  Copy the `SECRET_KEY`, `PUBLIC_KEY`, and `ID` values into your `.env` file.

> **Security:** Run `keygen` on a secure, offline laptop. The org signing key is
> the root of trust — never store it on a server, never commit it to git, never
> transmit it over the network.

## Step 1: Register an organization (OrgGenesis)

Use the `gen-bootstrap` tool to build and sign the event. It is available
as a Docker image — no source build needed.

### Using the attestation file (recommended)

```bash
# Pull the image
docker pull ghcr.io/stardome-technology/stardome-sead/gen-bootstrap:latest

# Register the org — feed the attestation binary directly.
# cd to the directory containing the attestation file first, then mount it:
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <secret_key_hex> \
  --org-public-key <public_key_hex> \
  --attestation-file /data/endorse_att.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

> **Important:** Docker only sees files inside mounted volumes. The
> `--attestation-file` path must be inside a directory you passed with
> `-v`. If the file is elsewhere, mount that directory instead:
> `docker run --rm -v /absolute/path/to/signatures:/data ...`

The `--attestation-file` option parses the CBOR attestation binary, extracts
`module_pk`, `merkle_root`, and `signature`, and derives `module_id` as
`SHAKE256(module_pk)` — no manual hex copy-paste needed.

### Using individual hex args (legacy)

```bash
docker run --rm ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <secret_key_hex> \
  --org-public-key <public_key_hex> \
  --module-id <module_id_hex> \
  --module-pk <module_pk_hex> \
  --module-merkle-root <merkle_root_hex> \
  --module-signature <module_sig_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

> **Important:** `--not-before` and `--not-after` must match the values the
> module endorsed in step 3a. If omitted, the tool defaults to `now` / `0`,
> which will cause a signature mismatch.

The output is a hex-encoded CBOR envelope. Use `--out-file` to write it to a file, then POST it:

```bash
# Write the envelope to a file (avoids terminal copy-paste issues)
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <secret_key_hex> \
  --org-public-key <public_key_hex> \
  --attestation-file /data/endorse_att.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-file /data/envelope.hex

# POST the file contents as the JSON value
# (the gateway requires a Bearer token — set SEAD_AUTH_SECRET in .env)
curl -X POST https://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d "{\"envelope_hex\": \"$(cat envelope.hex)\"}"

# Expected response:
# {"event_id":"<64-hex>","event_type":1,"event_type_name":"org_genesis","status":"accepted"}
```

> **Capture the event_id:** the POST response returns the org_genesis
> `event_id` (also printed to stderr by the generator as `org_genesis event_id:`).
> You will pass this to `edge-authorization --genesis-event-id` in Step 2.

> **Tip:** The envelope hex can be very large (XMSS signatures are ~18 KB).
> Using `--out-file` avoids terminal scroll and copy-paste truncation.

The body inside the envelope is equivalent to this JSON structure:

```json
{
  "org_id": <hex bytes>,
  "org_pk": <hex bytes>,
  "not_before": <unix timestamp>,
  "not_after": <0 or timestamp>,
  "module_endorsements": [
    [<module_id_hex>, <module_pk_hex>, <module_sig_hex>]
  ]
}
```

See [sead_v1.3.0.cddl](https://github.com/Stardome-technology/stardome-cbor-schemes/blob/main/sead_v1.3.0.cddl)
for the definitive CBOR schema.

## Step 2: Authorize an edge (EdgeAuthorization)

Once the org is registered, authorize an edge device using `gen-bootstrap`.
The edge-authorization must reference its `org_genesis` event via
`--genesis-event-id` (written into `dependency_refs[94]`); sead-core resolves
the authorization against that specific genesis (content-addressed authority
resolution). This flag is **required**.

> **Get the org-genesis event_id:** the `org-genesis` command in Step 1 prints
> `org_genesis event_id: <64-hex>` to **stderr**. Capture that 64-hex value and
> pass it below as `--genesis-event-id`.

```bash
# The 64-hex org_genesis event_id printed by the org-genesis command in Step 1:
GENESIS_EVENT_ID=<org_genesis_event_id_64hex>

docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <secret_key_hex> \
  --org-public-key <public_key_hex> \
  --genesis-event-id "$GENESIS_EVENT_ID" \
  --edge-id <edge_id_hex> \
  --edge-pk <edge_pk_hex> \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec> \
  --out-file /data/envelope.hex
```

> `--genesis-event-id` is mandatory: an `edge_authorization` with no
> `dependency_refs[94]` is rejected by sead-core (`ERR_MISSING_DEPENDENCY`).
> If the referenced org_genesis is not present yet, sead-core **holds** the
> authorization pending and promotes it automatically once the genesis lands
> (response `HELD_PENDING`). `--not-before` defaults to `now` if omitted,
> `--not-after` defaults to `0`. These are the edge's authorization window —
> independent of the org genesis values.

POST the output hex to sead-core:

```bash
curl -X POST http://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d "{\"envelope_hex\": \"$(cat envelope.hex)\"}"

# Verify:
curl http://localhost:30080/orgs/<org_id_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
# Expected: {"status":"active","org_pk_hex":"<pk>"}

curl http://localhost:30080/edges/<org_id_hex>/<edge_id_hex> \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET"
# Expected: {"status":"authorized","edge_pk_hex":"<pk>"}
```

The body inside the envelope is equivalent to this JSON structure:

```json
{
  "org_id": <hex bytes>,
  "edge_id": <hex bytes>,
  "edge_pk": <hex bytes>,
  "not_before": <unix timestamp>,
  "not_after": <0 or timestamp>
}
```

## Seed the org key index into edge-service (bootstrap → seed → first start)

`gen-bootstrap` accepts `--key-index-db <path>` on every org-key signing
subcommand (`org-genesis`, `edge-authorization`, `edge-revocation`,
`org-key-revoke`): a SQLite file persisting the org key's XMSS signer state
`{index, sk}` across runs — the same `key_index` table edge-service uses in
its `edge.db`. This file is the bridge between the offline bootstrap runs and
the edge: it is created before any edge exists, then handed to the edge as its
initial `edge.db`.

### 1. Bootstrap with a shared `--key-index-db`

Pass the **same** `--key-index-db` path to every `gen-bootstrap` run for one
org key, and run them **serialized** — org-genesis, then edge-authorization,
then any revocation. Concurrent runs sharing one key can reuse a leaf;
parallelism across *different* keys is safe.

```bash
# Step 1 (org-genesis): signs at leaf 0 and persists the advanced state.
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  <same args as Step 1> \
  --key-index-db /data/org-key-index.db

# Step 2 (edge-authorization): resumes from the DB, signs at leaf 1.
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  <same args as Step 2> \
  --key-index-db /data/org-key-index.db
```

A run **without** `--key-index-db` behaves as before (leaf index taken from the
SK hex) but prints a stderr warning naming the index used: signing more than
one message with the same key without a store reuses a WOTS+ one-time leaf and
leaks the key.

### 2. Seed: hand the index DB to the edge

**Fresh edge (no `edge.db` yet):** after the last `gen-bootstrap` run has
exited, copy the bootstrap DB to the edge's data volume as the initial
`edge.db`, before the first edge-service start:

```bash
cp org-key-index.db <edge-data-dir>/edge.db
```

A plain file copy is the whole handoff — the copied `key_index` row **is** the
initial index state, edge-service creates its own tables alongside it, and no
`edge-index-audit --seed` run is needed for the copy case.

**Merge into an existing `edge.db`:** use the `edge-index-audit --seed` rules:

```bash
./build/tools/edge-index-audit --sead-db <sead.db> \
  --edge-signing-key-file <edge_sk_file> \
  --edge-db <edge.db> --seed            # add --dry-run to preview the SQL
```

> ⚠️ **`edge-index-audit --seed` audits EDGE keys only — never use it to seed
> the ORG key from this bootstrap handoff.** The audit derives an index from
> the `edge_commit` events observed in `sead.db` for the key it scans. An org
> key never signs `edge_commit`s, so its consumed leaves (org-genesis @ leaf 0,
> edge-authorization @ leaf 1) are invisible to the scan and `--seed` would
> seed the org row at **idx=1 → leaf 1** — a WOTS+ one-time-key **reuse** of
> the leaf already signed by `edge-authorization` (full key compromise). The
> org-key handoff is the copy above; this command seeds the **edge** key's own
> row only.

The default path **refuses** to touch an existing `key_index` row (it reports
the existing index and writes nothing) — a default merge therefore never
lowers, nor alters at all, an existing index. `--force` is a human override
that overwrites unconditionally: treat it as a recovery tool for moving an
index **up** only, never script it against live signer state.

### 3. First edge-service start

Start edge-service with `--db` pointing at the seeded `edge.db` (compose:
`--db /data/edge.db`). Both signers open the same store:

- The **org signer** resumes from the seeded row: after org-genesis (leaf 0)
  and edge-authorization (leaf 1), the first org-key signature edge-service
  produces lands at leaf >= 2 — it is the `replication_endpoint_catalog`
  (event_type 60, authored via `PostCatalog`) when gossip-node runs,
  otherwise the first per-pin token in the commit flow.
- The **edge key** gets its own `key_index` row, created when edge-service
  first signs a catalog commit (leaf 0 of the edge key).

> **The rotation rule on state loss is UNCHANGED by index persistence.** Losing
> or rolling back persisted index state (volume destroyed by `down -v`, a stale
> `edge.db` restored, the key moved to a new deployment) remains a key-rotation
> event: revoke and replace the key — never resume signing from a reset index.
> See the rotation cases under **Key revocation** below.

## Step 3: Generate a token for IPFS pinning

> **Go-gateway migration:** the standalone `POST /auth/token` HTTP endpoint is
> **removed** — edge-service is gRPC-only and generates per-pin tokens
> **internally** during its commit flow (signed by the org key, `payload_hash`-bound)
> and sends them to storage-gateway's `/pin` over gRPC. There is no public
> HTTP endpoint to mint an arbitrary org-wide token anymore.

There are two ways to obtain a token:

### Option A — use edge-service's internal token (recommended, no manual step)

This is what production uses. When edge-service commits an artifact, it
automatically generates a pin token and calls storage-gateway's `/pin` with it.
You don't mint a token yourself — just ensure the **org signing key** is
configured in edge-service (env `EDGE_ORG_SIGNING_KEY`). No CLI/HTTP call needed.

### Option B — pre-generate an org-wide token with the `gen-token` CLI

Use this when you need a reusable token in advance (e.g. to set
`SEAD_AUTH_SECRET` on the broker, or to test against IPFS directly). Build the
tool, then run it on a **secure offline laptop** (the org signing key must never
leave it):

```bash
cmake -B build -DBUILD_TOOLS=ON && cmake --build build -j$(nproc)

# Payload-bound token (recommended — binds to a specific artifact)
./build/tools/gen-token \
  --org-id 0x<org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --payload-file payload.file   # or: --payload-hash <64-hex>

# Output: a single base64url string (RFC 4648 §5, no padding)
# suitable for: Authorization: Bearer <token>
```

Capture the output and use it in the IPFS API call:

```bash
TOKEN=<the base64url string from gen-token>

curl -X POST https://ipfs.stardome.cloud/api/v0/add \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@payload.file"
```

> **⚠️ `gen-token` is build-time/testing only — not for production.** Each
> invocation loads the key from hex and always starts at XMSS **index 0**,
> violating one-time-signature semantics. For production, prefer **Option A**
> (edge-service's internal, index-persisted token generation). If you must
> pre-generate tokens for a broker, generate them once per key index and treat
> the broker as the demo/reference flow — the VPS guide and broker README
> describe this (`SEAD_AUTH_SECRET`).

## Step 4: Verify end-to-end

```bash
curl -X POST \
  -H "Authorization: Bearer <base64url-encoded-cbor-token>" \
  -F file=@test_artifact.cbor \
  "https://ipfs.stardome.cloud/api/v0/add"
# Expected: 200 + CID
```

## Key revocation

Revoking an org key is a two-step operation: **generate** the signed
`org_key_revoke` envelope with the `gen-bootstrap` tool, then **POST** it.

> **Security:** like `org-genesis`, the revoke envelope must be built on a
> secure, offline laptop — it is signed with the **current (active) org
> signing key**, the same key material used for genesis.

### 1. Generate the revoke envelope

```bash
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-key-revoke \
  --org-id <org_id_hex> \
  --org-signing-key <current_org_secret_key_hex> \
  --org-public-key <current_org_public_key_hex> \
  --reason "key rotation" \
  --out-file /data/org_revoke.hex
```

| Flag | Required | Description |
|------|----------|-------------|
| `--org-id` | Yes | Organization ID (hex) of the key being revoked |
| `--org-signing-key` | Yes | The **active** org XMSS secret key — the revoke is self-signed by the key it revokes |
| `--org-public-key` | Yes | The org public key being revoked (written into the body) |
| `--genesis-event-id` | No | `org_genesis` event_id added as `dependency_refs[94]` (trust-anchor link) |
| `--revoke-time` | No | Unix seconds when the revocation takes effect (default: now) |
| `--reason` | No | Audit string (default: `manual`) |

### 2. POST the envelope

```bash
curl -X POST https://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d "{\"envelope_hex\": \"$(cat org_revoke.hex)\"}"

# Expected response:
# {"event_id":"<64-hex>","event_type":2,"event_type_name":"org_key_revoke","status":"accepted"}
```

After `revoke_time` the org key is **inactive**: `GET /orgs/<org_id>` reports
`"status":"inactive"` and verifiers reject new tokens/events signed by it.

**Re-enrolling after a rotation.** A fresh `org_genesis` is accepted only once
no active key exists for the `org_id` (otherwise `ERR_DUPLICATE_ORG`). Two
rotation cases:

- **New org key (new `org_id`):** the new genesis does not collide — POST it
  first, then revoke the old key. Zero gap where the org is inactive for pinning.
- **Same `org_id` (e.g. re-enrolling module endorsements):** revoke first, then
  POST the new genesis — the duplicate gate passes because the prior key is no
  longer active.

For the full end-to-end rotation procedure — generating the new XMSS keypair,
publishing it, and retiring the old key across a live federation — see the
[Organization Key Rotation Guide](org-key-rotation.md).
