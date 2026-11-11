# Hindsight digest — add-org-key-rotation-guide

Archived: 2026-11-11 · Branch: `feat/add-org-key-rotation-guide` · Type: documentation-only (`skip_specs: true`, zero spec deltas)

## What was built

The first end-to-end runbook for rotating a **live** org key across a running
federation (`docs/org-key-rotation.md`, 353 lines), distilled from the first
production rotation (2026-11-10, both lab edges). Sections: owner-side
bootstrap of the new key (shared `--key-index-db`), revoke-old → new genesis →
new edge-authorization POSTed to **every** node, index handoff into each edge's
`edge.db`, `.env` update + service recreation order, broker/peer config, and
verification gates (leaf ≥ 2 proof, cross-edge explorer replication check).

Supporting edits:
- `docs/bootstrap-genesis.md` — cross-link from "Key revocation" to the new
  guide; ⚠️ admonition under the `edge-index-audit --seed` merge case.
- `README.md` — one-line clarification at the `--seed` merge mention (§3d).
- `compose.yaml` — rotation comment block in the identity sections (edge-service
  and gossip-node env): which vars change on rotation, recreate-don't-restart,
  staggered gossip restart.

All work landed via the nicola bench per-card session lane (tasks 1.1–3.1 →
commits `07a9898`, `d1aae04`, `670cdf7`, `a2a68e1`, `628b637`); quality gate
4.1 (`openspec validate` @ 1.17.0) passed on `628b637`.

## Key decisions

1. **Separate file, not a section of `bootstrap-genesis.md`** — that file is the
   first-boot guide (~400 lines); rotation is a distinct operational event.
   Cross-linked both ways.
2. **Order = revoke-old first, then new genesis** — matches the accepted
   same-org_id re-enrolment gate (re-genesis requires the old key revoked);
   proven live. New-first variant noted only for distinct org ids.
3. **Index handoff = merge `org-key-index.db` rows with `INSERT OR IGNORE`,
   never `edge-index-audit --seed` for ORG keys** — the audit scans only
   `edge_commit` events, so on a fresh org it would seed idx=1 → leaf-1 WOTS+
   reuse (genesis@0 + auth@1 already consumed leaves 0–1). Warning box placed
   wherever `edge-index-audit` is mentioned.
4. **Config channel = untracked `.env` + full `docker compose up -d`** — every
   consuming service must be recreated (gossip included), not just `edge-service`.
5. **Stagger gossip restarts ~15 s** — back-to-back recreates leave the second
   dialer in libp2p dial backoff with `topic peers=0` and no retries; verify
   `topic peers=1` on both org topics.
6. **Secrets stay out of the repo** — guide references shared secrets/key files
   by name only.

## Deviations from plan

- The proposal named `.env.example` for the rotation notes; they landed in
  **`compose.yaml`** identity sections instead, where the vars are actually
  defined (task t_4d7d3716 specified compose.yaml; `.env.example` untouched).
- Task 4.2's "open MR" step is human-gated (protected `main`, squash-PR-only per
  AGENTS.md; orchestrator has no GitHub write credentials) — tracked on kanban
  t_14dbc747, which is blocked at the same capability wall as precedent
  t_0f92ae69. Commit+push on the change branch are done.

## Lessons learned

- **`edge-index-audit --seed` is edge-key-only and fails silently for org keys**
  (mis-seeds idx=1 → WOTS+ leaf reuse). Any doc mentioning the tool now carries
  the caveat inline — the trap produces no error, only weaker signatures.
- **Gossip identity vars are a second config surface** (`GOSSIP_ORG_ID`,
  `GOSSIP_OBSERVE_ORGS`): leaving them stale stops cross-edge replication of the
  new org's events with **no error surfaced**. Rotation docs must treat
  edge-service and gossip-node as one config unit.
- **libp2p dial backoff is an operational trap**: stagger container restarts
  (~15 s) after identity changes; a plain restart recovers a locked-out dialer.
- Process: doc-only changes still ride the full OpenSpec flow (proposal →
  design → per-task bench dispatch → validate gate → archive); the evidence
  comments in `tasks.md` (landing SHA per task) made this close-out trivial.
