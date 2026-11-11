# Design

## Context

See proposal.md - Why. Ground facts (verified in `stardome-sead-private`
`src/edge-service/edge_grpc_server.cpp::PostCatalog` and
`tools/sead-gossip-node/internal/observer/catalog.go`):

- PostCatalog gates BEFORE signing: foreign org → `ERR_ORG_MISMATCH`;
  inactive/unknown org (KeyResolver resolve → nullopt, cached TTL 60 s) →
  `ERR_ORG_NOT_ACTIVE`; missing signer/client → `ERR_INTERNAL`.
- Then: encode body → `event_id = SHAKE256(body)` → **org XMSS sign** (advances
  and persists the key index) → `sead_core_client->post_event(env)`.
- If `post_event` fails after signing, the leaf is already consumed; the gossip
  observer retries on its heartbeat, so repeated post-sign failures burn one
  leaf each. The pre-sign gates exist precisely to stop the steady-state
  polling case (node not yet enrolled) from grinding the index.
- The gossip observer authors its catalog at startup (and re-authors when no
  catalog is in DAG state), so with gossip-node running, the catalog is
  normally the first org-key signature after the bootstrap handoff → leaf 2.

## Goals / Non-Goals

- Goals: accurate leaf-consumption model in the doc; explicit list of org-key
  consumers in edge-service; honest leaf-burn caveat.
- Non-Goals: no code change (gates are correct and tested); no changes to the
  rotation guide beyond what already holds; no new diagrams.

## Decisions

- **Edit §3 in place + one short note block** rather than a new section: the
  error lives in one paragraph; the fix should be local and reviewable.
- **State the retry caveat without numbers** (no "N leaves per hour"): retry
  cadence is gossip config-dependent; the invariant that matters is
  "post-sign failure = one leaf".

## Risks / Trade-offs

- Doc must stay in sync if PostCatalog ever moves the sign after acceptance
  (e.g. pre-validated submit): the note names the exact order (gates → sign →
  post_event) so a reorder is visibly a doc-update trigger.
