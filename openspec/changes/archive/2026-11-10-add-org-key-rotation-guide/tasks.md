# Tasks

## 1. New runbook — docs/org-key-rotation.md

- [x] 1.1 Create `docs/org-key-rotation.md` with sections: Owner-side bootstrap (shared `--key-index-db`, link to `bootstrap-genesis.md`), Revoke old key (POST to every node), New genesis + edge-authorization (POST to every node), Index handoff (merge `org-key-index.db` rows with `INSERT OR IGNORE`; warning box: never `edge-index-audit --seed` for ORG keys), `.env` update + service recreation order (EDGE_*/GOSSIP_*; full `docker compose up -d`, not `edge-service` alone), Broker/peer config (per-edge `SEAD_AUTH_SECRET`, `EDGE_ORG_ID`), Verification (leaf ≥ 2 proof, cross-edge explorer check), Gossip restart guidance (stagger ~15 s to avoid libp2p dial-backoff lockout; verify `topic peers=1`).
  <!-- evidence 2026-11-10 nicola bench: landed in 07a9898 (docs/org-key-rotation.md runbook with all required sections) -->
- [x] 1.2 Cross-link from `docs/bootstrap-genesis.md` "Key revocation" section to the new rotation guide.
  <!-- evidence 2026-11-10 nicola bench: landed in d1aae04 (bootstrap-genesis.md Key revocation -> org-key-rotation.md link) -->

## 2. Clarifications in existing docs

- [x] 2.1 `docs/bootstrap-genesis.md`: add a warning that `edge-index-audit --seed` audits **edge** keys from observed `edge_commit` events and must NOT be used to seed an **org** key from a bootstrap handoff (would seed idx=1 → leaf-1 WOTS+ reuse).
  <!-- evidence 2026-11-10 nicola bench: landed in 670cdf7 (bootstrap-genesis.md --seed org-key warning) -->
- [x] 2.2 `README.md` (~line 715): same one-line clarification where `edge-index-audit --seed` is mentioned for the merge case.
  <!-- evidence 2026-11-10 nicola bench: landed in a2a68e1 (README.md --seed merge-case clarification) -->

## 3. `.env.example` rotation notes

- [x] 3.1 Add a comment block to the identity section: which vars change on rotation (EDGE_ORG_ID, EDGE_ID, EDGE_SIGNING_KEY, EDGE_ORG_SIGNING_KEY, EDGE_ORG_PUBLIC_KEY, GOSSIP_ORG_ID, GOSSIP_OBSERVE_ORGS, GOSSIP_BOOTSTRAP), that the gossip container must be recreated (not just edge-service), and the staggered-restart guidance.
  <!-- evidence 2026-11-10 nicola bench: landed in 628b637 (compose.yaml identity-section rotation comment block) -->

## 4. Quality gate

- [x] 4.1 `openspec validate add-org-key-rotation-guide` passes.
  <!-- evidence 2026-11-10 nicola bench: `npx -y @fission-ai/openspec@1.17.0 validate add-org-key-rotation-guide` on 628b637 -> "Change 'add-org-key-rotation-guide' is valid", exit 0 (INFO: skip_specs in .openspec.yaml, zero deltas accepted) -->
- [x] 4.2 Commit on `feat/add-org-key-rotation-guide`, push, open MR.
  <!-- evidence 2026-11-11 orchestrator close-out: commits pushed on feat/add-org-key-rotation-guide (tip incl. this archive); squash MR into main is human-gated per AGENTS.md (protected main, orchestrator has no GitHub write creds) and tracked on kanban t_14dbc747. -->
