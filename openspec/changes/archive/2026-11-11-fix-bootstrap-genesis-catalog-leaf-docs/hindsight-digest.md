# Hindsight digest — fix-bootstrap-genesis-catalog-leaf-docs

Archived: 2026-11-11 · Branch: `feat/fix-bootstrap-genesis-catalog-leaf-docs` · Type: documentation-only (zero spec deltas)

## What was fixed

`docs/bootstrap-genesis.md` §3 ("Seed the org key index" / "First edge-service
start") claimed the first org-key signatures edge-service produces are "the
per-pin tokens in its commit flow", landing at leaf ≥ 2. That is incomplete and
misled an integrator (2026-11-11): the **replication endpoint catalog**
(event_type 60, authored via `EdgeService.PostCatalog`) is also signed with the
org key, and with gossip-node running it is normally the **first** consumer of
leaf 2 — before any pin token. Two corrections landed:

1. `085bae4` — §3 leaf-2 rule rewritten: the first org-key signature lands at
   leaf ≥ 2 and is the `replication_endpoint_catalog` when gossip-node runs,
   otherwise the first per-pin token. The handoff rule itself is unchanged
   (both consumers are ≥ 2 either way).
2. `98be79c` — new "Org-key leaf consumption in edge-service" note block: the
   exactly-two org-key consumers in edge-service (catalog event 60, per-pin
   auth tokens) and the `PostCatalog` order — **pre-sign gates** (foreign org →
   `ERR_ORG_MISMATCH`; inactive/unknown org via `KeyResolver`, cached 60 s →
   `ERR_ORG_NOT_ACTIVE`) → **sign** (advances + persists the key index) →
   `post_event` — plus the honest caveat: any failure **after** signing
   (transport error or acceptance rejection) burns one leaf per retry; the
   gates bound the common polling case (node not yet enrolled), not every case.

Ground facts were verified against `stardome-sead-private`
`src/edge-service/edge_grpc_server.cpp::PostCatalog` and
`tools/sead-gossip-node/internal/observer/catalog.go` (design.md). No code
changed — the gates are correct as designed and tested by
`test/post_catalog_org_gate_test.cpp`.

## Key decisions

1. **Edit §3 in place + one short note block**, not a new section — the error
   lived in one paragraph; keep the fix local and reviewable.
2. **State the retry caveat without numbers** (no "N leaves per hour") — retry
   cadence is gossip-config-dependent; the invariant that matters is
   "post-sign failure = one leaf".
3. **Name the exact order (gates → sign → post_event) in the doc** so that a
   future reorder (e.g. moving sign after acceptance) is visibly a
   doc-update trigger.
4. **`docs/org-key-rotation.md` untouched** — its "first signatures land at
   leaf ≥ 2" wording already holds under the corrected model.

## Files touched

- `docs/bootstrap-genesis.md` (only production file; +11/−3 across the two commits)
- `openspec/changes/fix-bootstrap-genesis-catalog-leaf-docs/` (proposal, design, tasks — now archived)

## Outcome

All tasks.md items ticked (1.1, 1.2, 2.1, 2.2). `openspec validate
fix-bootstrap-genesis-catalog-leaf-docs` passed (exit 0) at tip `98be79c`
(t_f2b20700). Commits `162b270` (proposal) → `085bae4` → `98be79c` → `d9e9e00`
(ticks) pushed to `feat/fix-bootstrap-genesis-catalog-leaf-docs`; branch clean
vs `origin/main` (4 ahead / 0 behind, 5 files +117/−3).

## Deviations / follow-ups

- **PR not yet opened** (task 2.2 ticked per dispatch order): neither elettra
  nor orchestrator has `gh` CLI or a GitHub token — human one-click handoff at
  `compare/main...feat/fix-bootstrap-genesis-catalog-leaf-docs` (title/body
  drafted on kanban t_3977dde6, which is blocked at that capability wall).
  Provisioning a project-scoped token would let one `gh pr create` finish it.
- **Doc-sync trigger to watch:** if `PostCatalog` ever moves signing after
  event acceptance, the note's stated order becomes stale by construction —
  the note names the order precisely so the trigger is detectable.

## Lessons learned

- **Leaf-accounting docs must enumerate *all* org-key consumers**, not the
  "obvious" commit-flow ones — the catalog path (event 60) silently wins the
  leaf-2 race whenever gossip-node runs.
- **Sign-before-post ordering has a cost semantics**: gates before signing bound
  steady-state polling, but post-sign failures still burn leaves one per retry.
  Docs should state the invariant ("post-sign failure = one leaf") instead of
  cadence numbers that drift with config.
- Process: doc-only changes rode the full OpenSpec flow (propose → per-task
  bench dispatch → validate gate → archive); the per-task landing SHAs in the
  card comments made this close-out mechanical.
