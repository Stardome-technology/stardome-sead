# Bootstrap Genesis — First Org and Edge Registration

After deploying `sead-core`, you must register an organization and authorize an edge
before the auth stack can verify tokens. This is a one-time operational step.

> **Blank-node boot order (important).** `edge-service` fails-fast (exits) until
> its `edge_authorization` is resolvable in sead-core, and enrollment below is
> served by the gateway → sead-core path (edge-service is **not** required to
> POST these events). The gateway therefore does **not** wait on edge-service.
> On a fresh node (after `down -v` or a new deploy) a full `docker compose up -d`
> leaves **edge-service exited — expected**. Complete Step 1 (org-genesis) and
> Step 2 (edge-authorization) below, then start it:
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
  
  # Generate an organization keypair (default: XMSS-SHAKE_20_256)
  ./build/tools/keygen --label my-org --oid 0x09
  
  # Generate an edge keypair
  ./build/tools/keygen --label my-edge --oid 0x09
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

To revoke a compromised org key:

```bash
curl -X POST https://localhost:30080/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEAD_AUTH_SECRET" \
  -d '{"envelope_hex": "<org-key-revoke-envelope>"}'
```
