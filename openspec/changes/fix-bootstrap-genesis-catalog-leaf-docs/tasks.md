# Tasks

## 1. bootstrap-genesis.md corrections

- [x] 1.1 §3 "First edge-service start": replace the pin-token-only sentence with the accurate leaf-2 rule (first org-key signature = replication_endpoint_catalog when gossip-node runs, else first pin token; handoff rule unchanged).
- [ ] 1.2 Add a short note: org-key consumers in edge-service (catalog event 60 via PostCatalog, per-pin auth tokens); PostCatalog order = pre-sign gates (foreign org, inactive org, cached resolver) → sign → post_event; caveat: any post-sign failure burns one leaf per retry — gates bound the polling case, not all cases.

## 2. Quality gate

- [ ] 2.1 `openspec validate fix-bootstrap-genesis-catalog-leaf-docs` passes.
- [ ] 2.2 Commit on `feat/fix-bootstrap-genesis-catalog-leaf-docs`, push, open PR.
