# Proposal

## Why

`docs/bootstrap-genesis.md` ("Seed the org key index" §3) states that after the
bootstrap handoff "the first signatures edge-service produces with the org key
— the per-pin tokens in its commit flow — land at leaf >= 2". This is
incomplete and misled an integrator (2026-11-11): the **replication endpoint
catalog** (event_type 60) is also signed with the org key via
`EdgeService.PostCatalog`, and with gossip-node running it is normally the
**first** consumer of leaf 2 — before any pin token. The doc also does not
state the leaf-burn semantics of `PostCatalog`: it gates on foreign-org and
inactive-org **before** signing, but signing happens **before** `PostEvent`, so
any post-sign failure (transport error, acceptance rejection) consumes one XMSS
leaf per attempt.

## What Changes

- `docs/bootstrap-genesis.md` §3 "First edge-service start": correct the leaf
  accounting — leaf 2 is taken by the **first org-key signature edge-service
  produces**, which is the replication_endpoint_catalog when gossip-node is
  running (catalog authoring at observer start), otherwise the first pin
  token; both are ≥ 2 either way, so the handoff rule is unchanged.
- Add a short "org-key leaf consumption in edge-service" note listing the org
  key consumers (catalog event 60, per-pin auth tokens) and the PostCatalog
  pre-sign gates (foreign org → ERR_ORG_MISMATCH, inactive org →
  ERR_ORG_NOT_ACTIVE, resolver cached 60 s) plus the honest caveat: a
  sign-then-fail cycle (PostEvent transport/acceptance failure after signing)
  burns one leaf per attempt — the gates bound the common polling case, not
  every case.
- No code changes — documentation only (behavior is as designed and tested by
  `test/post_catalog_org_gate_test.cpp`).

## Capabilities

### New Capabilities

None (docs-only).

### Modified Capabilities

None.

## Impact

- `docs/bootstrap-genesis.md` only; `docs/org-key-rotation.md` leaf-≥2 proof
  wording stays valid (it already says "first signatures land at leaf ≥ 2").
