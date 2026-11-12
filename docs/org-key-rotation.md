# Org Key Rotation — Live Federation Runbook

End-to-end procedure for rotating an organization's XMSS signing key across an
already-running SEAD federation (all edges, brokers, and gossip peers). This is
the **live rotation** runbook: the org and its edges are enrolled and producing
commits, and the goal is to move them onto a fresh org key with bounded downtime
and verifiable proof that no one-time leaf was reused.

For the underlying primitives — `keygen`, `gen-bootstrap` command usage, the
revoke envelope format, and the first-boot index handoff — see
[bootstrap-genesis.md](bootstrap-genesis.md). This guide does not duplicate
those command tables; it fixes the **ordering**, the env/config surface, and
the verification gates.

## When to rotate

Rotate the org key when any of these is true:

- **Compromise or suspected compromise** of the org signing key or its index state.
- **Index-state loss or rollback** — the volume holding `edge.db` / the key-index
  store was destroyed (`docker compose down -v`), a stale `edge.db` was restored,
  or the key moved to a new deployment. Per the `key-index-store` spec, index-state
  loss **is** a rotation event: revoke and replace, never resume signing from a
  reset index.
- **Planned rotation** before the XMSS leaf budget is exhausted.

## Prerequisites

- A **secure, offline laptop** with the **old (current) org key** (needed to sign
  the revocation) and the **new org keypair** from `keygen`
  (see [bootstrap-genesis.md — Prerequisites](bootstrap-genesis.md#prerequisites)).
- The `gen-bootstrap` Docker image (or a local build that supports
  `--key-index-db`).
- The gateway URL and `SEAD_AUTH_SECRET` (Bearer) of **every** node in the
  federation, and the location of each edge's `edge.db` (the `sead_data` volume).
- The list of edges under this org (org id, edge ids, hosts).
- A chosen rotation window. Between step 2 (revoke) and step 5 (service
  recreation) the edges cannot sign new commits with the org key — commits and
  pins pause; already-published data is unaffected.

> **Same-org_id re-enrolment gate.** Re-registering the **same** org id requires
> the old key to be **revoked first** — this runbook therefore revokes (step 2)
> before the new genesis (step 3). The new-genesis-first variant (old and new key
> briefly both valid) is only available when you rotate to a **distinct** org id;
> it is not covered here.

> **Secrets stay out of the repo.** Key material and per-node gateway secrets are
> referenced by name only. Never paste XMSS secret keys into tickets, chats, or
> git.

---

## 1. Owner-side bootstrap of the new org key

All signing in this section happens on the offline laptop. Every `gen-bootstrap`
run for the **new** org key shares **one** `--key-index-db` file
(`org-key-index.db`) and runs **serialized** — never two `gen-bootstrap` runs
concurrently on the same org key (SQLite transactions do not make
load→sign→save atomic across processes; concurrent runs can reuse a leaf).

```bash
# 1a. New org genesis (signs at leaf 0, persists {index, sk} to the shared DB)
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <new_org_secret_key_hex> \
  --org-public-key <new_org_public_key_hex> \
  --attestation-file /data/endorse_att.bin \
  --not-before <unix_epoch_sec> --not-after <unix_epoch_sec> \
  --key-index-db /data/org-key-index.db \
  --out-file /data/new_genesis.hex
# Capture the printed "org_genesis event_id: <64-hex>" → NEW_GENESIS_EVENT_ID

# 1b. Edge authorization for EACH edge of the org (leaf 1, 2, … — one per run)
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap edge-authorization \
  --org-id <org_id_hex> \
  --org-signing-key <new_org_secret_key_hex> \
  --org-public-key <new_org_public_key_hex> \
  --genesis-event-id "$NEW_GENESIS_EVENT_ID" \
  --edge-id <edge_id_hex> --edge-pk <edge_pk_hex> \
  --key-index-db /data/org-key-index.db \
  --out-file /data/edge_auth_<edge_id_hex>.hex
```

Full flag semantics: [bootstrap-genesis.md — Steps 1–2](bootstrap-genesis.md#step-1-register-an-organization-orggenesis).

> **Never run `gen-bootstrap` without `--key-index-db`** when signing more than
> one envelope with the same key: each storeless run starts at the leaf index
> embedded in the SK hex and reuses a WOTS+ one-time leaf, which leaks the key.
> The tool prints a stderr warning when you do — treat it as a stop signal.

Keep `org-key-index.db` — it is the handoff artifact for step 4.

## 2. Revoke the old key

Generate the `org_key_revoke` envelope with the **old (active)** org key — the
revoke is self-signed by the key it revokes (see
[bootstrap-genesis.md — Key revocation](bootstrap-genesis.md#key-revocation)):

```bash
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-key-revoke \
  --org-id <org_id_hex> \
  --org-signing-key <old_org_secret_key_hex> \
  --org-public-key <old_org_public_key_hex> \
  --reason "key rotation" \
  --out-file /data/org_revoke.hex
```

**POST the revoke to every node** — every sead-core must observe the revocation
before it will accept the same-org re-genesis of step 3; a node that never sees
it keeps trusting the old key:

```bash
for NODE in https://edge-a.example.com:30080 https://edge-b.example.com:30080; do
  curl -sk -X POST "$NODE/events" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer <node SEAD_AUTH_SECRET>" \
    -d "{\"envelope_hex\": \"$(cat org_revoke.hex)\"}"
done
# Expected per node:
# {"event_id":"<64-hex>","event_type":2,"event_type_name":"org_key_revoke","status":"accepted"}
```

Verify on **each** node that the old key is no longer active:

```bash
curl -sk https://<node>:30080/orgs/<org_id_hex> -H "Authorization: Bearer <secret>"
```

## 3. New genesis + edge-authorization

POST the envelopes generated in step 1, in the same order they were signed, to
**every** node (the envelope bytes — and therefore the `event_id`s — are
identical on every node):

```bash
# 3a. New org genesis — every node
for NODE in https://edge-a.example.com:30080 https://edge-b.example.com:30080; do
  curl -sk -X POST "$NODE/events" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer <node SEAD_AUTH_SECRET>" \
    -d "{\"envelope_hex\": \"$(cat new_genesis.hex)\"}"
done
# Expected: {"event_type":1,"event_type_name":"org_genesis","status":"accepted"}

# 3b. Edge authorization (new key) — every node, every edge
for NODE in https://edge-a.example.com:30080 https://edge-b.example.com:30080; do
  curl -sk -X POST "$NODE/events" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer <node SEAD_AUTH_SECRET>" \
    -d "{\"envelope_hex\": \"$(cat edge_auth_<edge_id_hex>.hex)\"}"
done
# Expected: {"event_type":3,"event_type_name":"edge_authorization","status":"accepted"}
```

Verify on **each** node:

```bash
curl -sk https://<node>:30080/orgs/<org_id_hex> -H "Authorization: Bearer <secret>"
# Expected: {"status":"active","org_pk_hex":"<new_org_pk_hex>"}

curl -sk https://<node>:30080/edges/<org_id_hex>/<edge_id_hex> -H "Authorization: Bearer <secret>"
# Expected: {"status":"authorized","edge_pk_hex":"<edge_pk_hex>"}
```

## 4. Index handoff — merge `org-key-index.db` into each edge's `edge.db`

Each edge-service must resume the **new** org key at the first leaf *after* the
bootstrap runs consumed theirs. Copy the rows of `org-key-index.db` (step 1)
into the edge's `edge.db` `key_index` table **before** restarting edge-service
with the new key.

> ⚠️ **NEVER use `edge-index-audit --seed` for an ORG key.** The audit tool
> counts only `edge_commit` events signed by the key it scans. An org key never
> signs `edge_commit`s — its consumed leaves (genesis @ 0, authorizations @ 1+,
> per-pin tokens) are invisible to the scan — so `--seed` would compute
> `max_used + 1 = 1` and seed the org signer back to **leaf 1**, causing a
> WOTS+ one-time-key **reuse** of an already-signed leaf and full key
> compromise. `edge-index-audit --seed` is for **edge** keys only. The org-key
> handoff is the row merge below.

**Fresh edge (no `edge.db` yet):** a plain copy is the whole handoff —
see [bootstrap-genesis.md — Seed the org key index](bootstrap-genesis.md).

**Existing edge.db (the rotation case):** stop the edge signer, back up, then
merge with `INSERT OR IGNORE` — the row for a `key_id` that already exists is
left untouched, so the merge can never lower or rewind an existing index:

```bash
cd ~/stardome-sead   # same compose directory as always
docker compose stop edge-service

docker run --rm \
  -v "$(docker volume inspect --format '{{ .Name }}' <project>_sead_data)":/data \
  -v "$(pwd)":/boot \
  sqlite/sqlite3:3.45 /bin/sh -c '
    cp /data/edge.db /data/edge.db.bak-rotation
    sqlite3 /data/edge.db "ATTACH DATABASE '"'"'/boot/org-key-index.db'"'"' AS boot;
      INSERT OR IGNORE INTO main.key_index (key_id, idx, updated_at, sk)
        SELECT key_id, idx, updated_at, sk FROM boot.key_index;"
  '

# Confirm the new org key's row is present with idx >= 2 (leaves 0..N consumed by bootstrap):
docker run --rm -v <project>_sead_data:/data sqlite/sqlite3:3.45 \
  sqlite3 /data/edge.db "SELECT key_id, idx FROM key_index;"
```

(If you run the stack with bind-mounted data instead of a named volume, run the
same two `sqlite3` statements directly against the host `edge.db` path.)

The new org key has **no** `key_index` row in a pre-rotation `edge.db`, so
`INSERT OR IGNORE` inserts the bootstrap row verbatim (full `{idx, sk}` state).
If a row for that key somehow already exists, the merge keeps the existing one —
if its `idx` is **lower** than the bootstrap row's, do **not** start edge-service:
reconcile manually (the higher index is the only safe state; see the
`key-index-store` spec's never-rewind rule).

## 5. `.env` update + service recreation

Update the node's `.env` (per edge) to the new identity:

| Variable | New value on rotation |
|---|---|
| `EDGE_ORG_SIGNING_KEY_FILE` | a file holding the **new** org secret key (bare hex, mode `0400`, owned by `100:101` on native Docker Engine on Linux; see the README, "Key files") |
| `EDGE_ORG_PUBLIC_KEY_FILE` | a file holding the **new** org public key |
| `EDGE_ORG_ID` | unchanged for a same-org_id rotation; new org id only in the distinct-org variant |
| `EDGE_ID` / `EDGE_SIGNING_KEY_FILE` | only if the **edge** key is rotated too |
| `EDGE_AUTHORIZATION_EVENT_ID` | leave empty (auto-resolved from sead-core) or set to the new `edge_authorization` event id |
| `GOSSIP_ORG_ID` / `GOSSIP_OBSERVE_ORGS` | unchanged for same-org_id; new org id in the distinct-org variant |
| `GOSSIP_BOOTSTRAP` | unchanged (transport PeerIDs are not org identity) |
| `OBSERVER_ORG_ID` (explorer) | same rule as `GOSSIP_ORG_ID` |

Then recreate the stack **in full**:

```bash
cd ~/stardome-sead
docker compose -f docker-compose.remote.yml up -d
```

> **Do not recreate `edge-service` alone.** `gateway`, `gossip-node`, and the
> explorer also consume the rotated identity vars (`EDGE_*`, `GOSSIP_*`,
> `OBSERVER_ORG_ID`). `docker compose up -d edge-service` leaves every other
> container running with the **old** env — a gossip-node left on the old
> `GOSSIP_ORG_ID`/`GOSSIP_OBSERVE_ORGS` silently stops cross-edge replication
> of the new org's events, with **no error surfaced**.

> Always `cd` into the compose directory first: `GOSSIP_IDENTITY_DIR` defaults
> to `~/.sead/gossip-keys` resolved **relative to the compose working
> directory** — running `up -d` from elsewhere rotates the libp2p PeerID and
> breaks every published `GOSSIP_BOOTSTRAP` entry
> ([setup-vps.md §5.2](setup-vps.md)).

Recreate the gossip nodes with the stagger described in section 7.

## 6. Broker / peer config

- **`SEAD_AUTH_SECRET` is per-edge.** Each node's gateway enforces its own
  shared secret; each broker must present the secret of **its own** edge. If
  the rotation is also an opportunity to refresh them: generate a fresh
  `openssl rand -hex 32` per edge, set it in that node's `.env` (gateway) **and**
  the broker's env, then recreate both. Never reuse one secret across edges.
- **Broker `EDGE_ORG_ID`** must match the org id the broker ingests for —
  unchanged for a same-org_id rotation; update it (and the broker's target
  edge) in the distinct-org variant.
- **Old-key tokens are dead.** Anything signed by the revoked org key —
  pre-generated `gen-token` strings, `GATEWAY_EDGE_TOKENS`,
  `GATEWAY_PEER_TOKEN` values derived from the old key — is rejected after the
  revoke lands. Regenerate peer tokens against the new key on every node and
  update `GATEWAY_PEERS`/`GATEWAY_PEER_TOKEN`/`GATEWAY_EDGE_TOKENS` where they
  embed old-key material.

## 7. Gossip restart guidance (stagger ~15 s)

When both ends of the mesh are recreated close together, the second dialer can
get stuck in libp2p **dial backoff** against a peer that was briefly down:
`topic peers=0` with no further retries, and the mesh silently stops sharing
frontiers. Avoid it by staggering:

```bash
# Node A
docker compose restart gossip-node
sleep 15
# Node B
docker compose restart gossip-node
```

Wait **~15 s** between ends (longer than one gossip heartbeat,
`GOSSIP_HEARTBEAT_SEC=10`) so the restarted peer has re-announced its frontier
before the next end dials it.

Verify on **both** nodes:

```bash
docker logs --since 5m "$(docker compose ps -q gossip-node)" 2>&1 | grep "topic peers"
# Expected: "published frontier for org <org_id> (N heads, topic peers=1)"
# — topic peers=1 on each observed org topic for a two-edge mesh (>0 generally).
```

`topic peers=0` persisting after a staggered restart is a transport problem
(check `GOSSIP_BOOTSTRAP` multiaddrs, `GOSSIP_ADVERTISE`, port 31002 reachability)
— not an authority problem; do not re-sign anything to "fix" it.

## 8. Verification

Run all gates on **every** edge before declaring the rotation done:

1. **Org + edge status** (step 3 checks) show the **new** `org_pk_hex` active
   and every edge authorized.

2. **Leaf ≥ 2 proof** — the org-key handoff actually took:

   ```bash
   docker run --rm -v <project>_sead_data:/data sqlite/sqlite3:3.45 \
     sqlite3 /data/edge.db "SELECT key_id, idx FROM key_index;"
   ```

   The **new org key's** row must read `idx >= 2`: leaves 0 and 1 were consumed
   by `org-genesis` and the first `edge-authorization`, and edge-service resumed
   past them (its first per-pin token lands at leaf ≥ 2). A row at `idx` 0 or 1
   means the merge did not take — **stop edge-service**, redo section 4; do not
   let it sign.

3. **Live commit flow** — trigger (or wait for) one `edge_commit` on the edge and
   confirm it is accepted by sead-core and pinned (edge key signs the commit;
   the per-pin token is signed by the **new** org key).

4. **Cross-edge explorer check** — open each edge's explorer and confirm it
   shows the **peer edge's new commits** for the org (identical head sets on
   both explorers, matching the `topic peers=1` from section 7). Replication
   that stopped with the old org id but resumes only locally means a gossip-node
   kept stale `GOSSIP_*` env — go back to section 5.

5. **Old key is dead** — replay any envelope signed with the old key (e.g. an
   old edge-authorization) against a node and confirm it is rejected.

## If something fails

- **Revoke accepted on only some nodes:** re-POST step 2 to the missing nodes;
  do not proceed to step 3 until every node shows the revoke.
- **edge-service fail-fast on start** (`edge_authorization` not resolvable):
  step 3b has not landed on that node — POST it there, then
  `docker compose up -d edge-service`.
- **Leaf index looks wrong at any point:** the rotation rule applies — the key
  whose index state is in doubt is **revoked and replaced**; never resume
  signing from a reset or unverified index.

---

*Proven live on the 2026-11-10 rotation (both lab edges). Primitives and
envelope formats: [bootstrap-genesis.md](bootstrap-genesis.md). VPS/mesh
details: [setup-vps.md](setup-vps.md).*
