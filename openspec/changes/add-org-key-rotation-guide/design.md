# Design

## Context

See proposal.md - Why. The proven live rotation (2026-11-10) exercised the whole
stack; the guide must capture the exact ordering and the two traps. Existing
docs already cover the primitives (`gen-bootstrap` commands, revoke envelope,
index handoff mechanics in `docs/bootstrap-genesis.md`) — the new guide links to
them instead of duplicating command tables.

## Goals / Non-Goals

- Goals: one linear runbook an operator can follow to rotate a live org key
  with zero or bounded downtime; explicit verification gates; the two traps
  called out inline.
- Non-Goals: no changes to tooling, no new CLI flags, no protocol/spec changes;
  do not re-document `gen-bootstrap`/`keygen` usage (link to
  `bootstrap-genesis.md`).

## Decisions

- **New file `docs/org-key-rotation.md` instead of a section in
  `bootstrap-genesis.md`**: that file is the first-boot guide and is already
  ~400 lines; rotation is a distinct operational event. Cross-link both ways.
- **Order = revoke-old first, then new genesis** (zero-gap alternative noted):
  matches the accepted re-enrolment gate (same-org_id re-genesis requires the
  old key revoked) and was proven live; the guide notes the new-first variant
  only for distinct org ids.
- **Index handoff = merge `org-key-index.db` rows with `INSERT OR IGNORE`**,
  never `edge-index-audit --seed`, for ORG keys: the audit tool's scan counts
  only `edge_commit` events, so on a freshly rotated org it would seed idx=1
  and cause leaf-1 WOTS+ reuse (genesis@0 + auth@1 already used leaves 0-1).
  Stated as a warning box wherever `edge-index-audit` is mentioned.
- **Config channel = untracked `.env` + `docker compose up -d`** (compose split
  made compose.yaml env-driven); guide states every affected var
  (EDGE_*/GOSSIP_*/OBSERVER_ORG_ID/broker EDGE_ORG_ID) and that **all**
  services consuming them must be recreated, gossip included.
- **Gossip restart guidance**: stagger the two ends (start A, wait ~15 s, start
  B) — back-to-back recreates can leave the second dialer in libp2p dial
  backoff with `topic peers=0` and no retries; a staggered plain restart
  recovers it. Verification = `topic peers=1` on both org topics + each
  explorer showing the peer edge's new commits.
- **Secrets stay out of the repo**: guide references per-node gateway shared
  secrets and key files by name only.

## Risks / Trade-offs

- Runbook drift: the guide references live tooling behavior; mitigated by
  keeping command usage in `bootstrap-genesis.md` (single source) and limiting
  the new file to ordering, env, and verification.
- The dial-backoff workaround is operational, not a code fix; if gossip-node
  later retries bootstrap dials indefinitely, the note becomes historical —
  acceptable.
