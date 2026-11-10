# Tasks

## 1. New runbook — docs/org-key-rotation.md

- [ ] 1.1 Create `docs/org-key-rotation.md` with sections: Owner-side bootstrap (shared `--key-index-db`, link to `bootstrap-genesis.md`), Revoke old key (POST to every node), New genesis + edge-authorization (POST to every node), Index handoff (merge `org-key-index.db` rows with `INSERT OR IGNORE`; warning box: never `edge-index-audit --seed` for ORG keys), `.env` update + service recreation order (EDGE_*/GOSSIP_*; full `docker compose up -d`, not `edge-service` alone), Broker/peer config (per-edge `SEAD_AUTH_SECRET`, `EDGE_ORG_ID`), Verification (leaf ≥ 2 proof, cross-edge explorer check), Gossip restart guidance (stagger ~15 s to avoid libp2p dial-backoff lockout; verify `topic peers=1`).
- [ ] 1.2 Cross-link from `docs/bootstrap-genesis.md` "Key revocation" section to the new rotation guide.

## 2. Clarifications in existing docs

- [ ] 2.1 `docs/bootstrap-genesis.md`: add a warning that `edge-index-audit --seed` audits **edge** keys from observed `edge_commit` events and must NOT be used to seed an **org** key from a bootstrap handoff (would seed idx=1 → leaf-1 WOTS+ reuse).
- [ ] 2.2 `README.md` (~line 715): same one-line clarification where `edge-index-audit --seed` is mentioned for the merge case.

## 3. `.env.example` rotation notes

- [ ] 3.1 Add a comment block to the identity section: which vars change on rotation (EDGE_ORG_ID, EDGE_ID, EDGE_SIGNING_KEY, EDGE_ORG_SIGNING_KEY, EDGE_ORG_PUBLIC_KEY, GOSSIP_ORG_ID, GOSSIP_OBSERVE_ORGS, GOSSIP_BOOTSTRAP), that the gossip container must be recreated (not just edge-service), and the staggered-restart guidance.

## 4. Quality gate

- [ ] 4.1 `openspec validate add-org-key-rotation-guide` passes.
- [ ] 4.2 Commit on `feat/add-org-key-rotation-guide`, push, open MR.
