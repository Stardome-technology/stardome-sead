# Proposal

## Why

Org-key rotation is currently documented only as isolated primitives — revoke
envelope generation and re-enrolment rules live in `docs/bootstrap-genesis.md`,
the index handoff in its "Seed the org key index" section — but there is no
end-to-end runbook for rotating a **live** org key across an already-running
federation. The first production rotation (2026-11-10, both lab edges) had to be
assembled ad hoc and hit two documented-worthy traps: `edge-index-audit --seed`
silently mis-seeds ORG keys (it scans only `edge_commit` events → would re-use
leaf 1), and a gossip-node left on the old `GOSSIP_ORG_ID`/`GOSSIP_OBSERVE_ORGS`
stops cross-edge replication of the new org's events with no error surfaced.

## What Changes

- New `docs/org-key-rotation.md`: the full live-rotation runbook — owner-side
  bootstrap of the new org key (shared `--key-index-db`), revoke-old → new
  genesis → new edge-authorization POSTed to **every** node, index handoff into
  each edge's `edge.db`, `.env` update + service recreation order, broker/peer
  config updates, and verification steps (leaf ≥ 2 proof, cross-edge
  replication check).
- `.env.example`: add rotation notes to the identity block (which vars change
  on rotation, gossip env must be updated **and** the container recreated,
  stagger gossip restarts to avoid libp2p dial-backoff lockout).
- `docs/bootstrap-genesis.md` + `README.md`: one-line clarifications that
  `edge-index-audit --seed` audits **edge** keys from observed commits and must
  NOT be used to seed an **org** key from a bootstrap handoff (use the
  `org-key-index.db` rows / `INSERT OR IGNORE` merge).

No code, schema, or protocol changes — documentation only.

## Capabilities

### New Capabilities

None — documentation-only change (no spec-level behavior changes).

### Modified Capabilities

None.

## Impact

- `docs/org-key-rotation.md` (new), `docs/bootstrap-genesis.md` (clarification),
  `README.md` (clarification + link), `.env.example` (rotation notes).
- No runtime behavior, API, or schema impact.
