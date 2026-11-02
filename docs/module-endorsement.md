# Module endorsement and the org lifecycle

Who an org's hardware endorsements bind, how the enrolled-module set evolves,
and when it is enforced. This is the integrator-facing view; the normative
reference lives in the SEAD service documentation (doc 14).

## What an endorsement is

An `org_genesis` body carries `module_endorsements`: one or more entries of

```text
[module_id, module_pk, merkle_root, signature]   ; module_id = SHAKE256(module_pk)
```

Each is the Stardome module's own XMSS (OID `0x05`, device-bound, never
exportable) signature over the Merkle root of
`[org_id, org_pk, not_before, not_after]`. It proves the org key was endorsed
by genuine Stardome hardware. Produce one per module with
`stardome-client endorse`, embed it with `gen-bootstrap org-genesis
--attestation-file`.

## The binding is org ↔ module

- The enrolled-module set belongs to the **org**, not to any edge. Any module
  enrolled for the org may attest for any of the org's edges.
- **Every module that will ever sign attestations for the org must be
  enrolled** — otherwise hardware challenges against that org answer
  `mismatch` for that module.
- The schema allows n endorsements per genesis (threshold k ≥ 1; module_ids
  must be distinct within the list; each signature is verified at accept).

## The enrolled set only grows

The effective enrolled set is the **append-only union** of the endorsements of
every `org_genesis` accepted for the org. No protocol event removes a module.

- **Add a module later:** post `org_key_revoke` (see `gen-bootstrap
  org-key-revoke`), then a fresh `org_genesis` for the same org key listing
  the new module. The duplicate-org gate passes because the revoked key is no
  longer active.
  - Schedule the gap: between revoke and re-genesis the org key is inactive
    and edges stop committing.
  - Window-reuse trick: if the re-genesis reuses the exact same
    `not_before`/`not_after`, the existing endorsement bytes stay valid and
    only the new module must sign. Changing the window means every module
    re-endorse (module must be physically present).
- **Remove a module:** not possible via protocol. A compromised/retired
  module stays enrolled forever; the only remedy is a new org key — i.e. a new
  org (`org_id` is derived from `org_pk`).

## When enrollment is enforced

Never at ingest. Ingest validates only the DAG-layer edge signature (`0x12`).
The enrolled set is consulted only on the intentional challenge surface:
`POST /verify` on a node's gateway → `CheckHardwareConsistency` ("is the
module behind this edge the one its org enrolled?"). This is the decentralized
model: any peer may challenge any node at any time, and the answer is
re-provable for the node's whole operating life.

## "Organization" is a functional unit

An organization on the SEAD is **the smallest logical unit that can exist on
the DAG and spin edges** — not "the company that owns the modules". You may
run many orgs per operator, and you may **postpone modules**: if a module is
not online yet, genesis with what you have (k ≥ 1) and extend the enrolled
set later via revoke → re-genesis, on your own schedule.

Module sharing across orgs is protocol-legal but discouraged: the endorsement
is the org key's hardware provenance, and sharing entangles two orgs' roots
of trust. Keep enrolled sets disjoint per operational owner.

## Tooling note

`gen-bootstrap org-genesis --attestation-file` is **repeatable**: pass one
attestation file per module and the genesis carries all of them, in argument
order (duplicate modules are rejected by the tool before signing). Example
with two modules, both endorsing the same window:

```bash
docker run --rm -v "$(pwd):/data" \
  ghcr.io/stardome-technology/stardome-sead/gen-bootstrap org-genesis \
  --org-id <org_id_hex> \
  --org-signing-key <org_secret_key_hex> \
  --org-public-key <org_public_key_hex> \
  --attestation-file /data/endorse_att_m1.bin \
  --attestation-file /data/endorse_att_m2.bin \
  --not-before <unix_epoch_sec> \
  --not-after <unix_epoch_sec>
```

Modules added **after** the genesis still join via the revoke → re-genesis
lifecycle above.
