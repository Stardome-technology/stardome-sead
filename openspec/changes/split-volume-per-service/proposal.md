# Proposal: Split the Shared Volume Per Service

## Why

Every service mounts the same `sead_data` volume at `/data`:

```
sead-core            sead_data:/data   → sead.db
edge-service         sead_data:/data   → edge.db        ← XMSS key indices
pin-service          sead_data:/data   → pin-service.db
source-data-service  sead_data:/data   → sourcedata.db
```

`edge.db` holds the XMSS one-time key indices. Losing it, or restoring an old copy of it, means the
edge re-signs from an index it already spent — silent forgery, not a recoverable error. Every other
database in that volume is ordinary state that can be rebuilt or restored from a backup.

Sharing one volume couples those fates. A `docker compose down -v` wipes all four. A backup of the
volume includes `edge.db`, so restoring it is a trap. A migration or a disk-full event on one database
threatens the key index.

## What Changes

- **One volume per service**, with `edge.db` on a volume of its own that is never deleted.
- **A migration** from the shared `sead_data` volume to the new per-service volumes, run with the
  stack stopped. After copying, it renames the old `edge.db` inside `sead_data` so that falling back
  to the old files makes edge-service **fail** rather than sign with already-spent indices.
- **`external: true` on the `edge.db` volume**, so on an updated node without the migration `up`
  stops with an error instead of starting edge-service against an empty `edge.db`.
- **A backup script** for `sead.db`, `sourcedata.db` and `pin-service.db` that deliberately **excludes**
  `edge.db`, because restoring an old copy of it reuses spent XMSS indices.
- **Documentation** that losing `edge.db` or restoring an old copy requires rotating the edge key,
  consistent with the README's "XMSS key-state persistence" section, and a warning against
  `docker compose down -v`.

## Capabilities

### New Capabilities

- `per-service-volumes`: the volume layout, the `edge.db` isolation guarantee, and the `external`
  declaration that makes a missing migration fail loudly.
- `volume-migration`: the stop-the-stack migration procedure and its safety properties.
- `database-backup`: which databases are backed up, which is excluded and why, and the integrity
  check that gates a successful backup.

### Modified Capabilities

- None. No service behaviour changes; only where its data lives.

## Impact

- **Compose**: `compose.yaml` (per-service volumes, top-level volume declarations),
  `compose.production.yaml` (the hardening text that currently refers to `sead_data`).
- **Scripts**: a migration script and a backup script, both new.
- **Docs**: the README's volume and XMSS-persistence sections; a new update runbook.
- **Blast radius: high if done wrong, zero if done right.** The migration touches the only copy of the
  XMSS key index. It must be idempotent, must verify before declaring success, and must leave the old
  files recoverable-but-poisoned (renamed) rather than deleted.
- **Operational prerequisite — RE-VERIFIED 2026-11-17, the earlier note was stale.** Both edges are
  at `dcd5fa3` with `M compose.yaml` / `M compose.production.yaml` in `git status`, but
  `git diff origin/main -- compose.yaml compose.production.yaml` is **empty**: the local content is
  byte-identical to `origin/main` (the hardening PR landed as #39, `e9c1e15`). There is nothing to
  reconcile and nothing to lose — `git checkout -- compose.yaml compose.production.yaml` clears the
  dirty flag with no content change. The runbook still starts with a verification step, but it is a
  check, not a merge.
- **The key files already exist on both edges.** `~/stardome-sead/keys/` holds `edge_sign.hex`,
  `org_sign.hex`, `org_pub.hex`, mode `0400`, owned `10001:10001`, and `.env` already
  sets `EDGE_SIGNING_KEY_FILE` / `EDGE_ORG_SIGNING_KEY_FILE` / `EDGE_ORG_PUBLIC_KEY_FILE` to them.
  So the #37 secrets prerequisite is satisfied; the runbook verifies it rather than creating it.
- **`keys/` is gitignored on `origin/main` but not in the edges' `dcd5fa3` `.gitignore`.** The entry
  arrived after `dcd5fa3`, so on the current checkout `git status` shows `?? keys/`. After the pull
  the directory becomes ignored and the untracked marker disappears. The runbook must not treat
  `?? keys/` as a problem to clean up — deleting it destroys the edge signing key.
- **No backups exist today.** `~/backups` and `/mnt/data` are absent on both edges, so the backup
  script is the first one and has nothing to sit alongside.
- **Updates are manual**: `git pull` then `docker compose -f compose.yaml -f compose.production.yaml
  up -d`, by hand. No systemd unit, no update script. The migration step therefore has to be an
  explicit script the operator runs, not something an `up -d` triggers.
- **Not in scope**: `compose.relay.yaml` (the relay has no databases).
