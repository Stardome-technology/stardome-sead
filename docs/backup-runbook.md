# Database Backup Runbook

What `scripts/backup_databases.sh` covers, what it deliberately excludes
and why, and where the snapshots land. The mechanics live in the script
(header + `--help`); this document is the human-facing contract around it.
Design rationale: `openspec/changes/split-volume-per-service/design.md`
(D5 — exclusion by construction, D6 — host-directory destination).

The per-service volume layout the backup reads from is documented in the
README ([Volumes](../README.md#volumes)); moving an existing node onto that
layout is [update-runbook.md](update-runbook.md).

## What it covers

Three databases, read from their per-service volumes:

| Database | Source volume | Service |
|----------|---------------|---------|
| `sead.db` | `stardome-sead_sead_core_data` | sead-core |
| `sourcedata.db` | `stardome-sead_sourcedata_data` | source-data-service |
| `pin-service.db` | `stardome-sead_pin_data` | pin-service |

Each is snapshotted **while the stack keeps running** — unlike the
migration, the backup does not require a stopped stack. Per database: a
WAL checkpoint (`PRAGMA wal_checkpoint(TRUNCATE)`, a busy reply is
tolerated), then a consistent single-file snapshot via the SQLite Online
Backup API (`sqlite3 .backup`), then verification of the copy with
`PRAGMA integrity_check` (must print `ok`). The snapshot is self-contained
— no `-wal`/`-shm` sidecars to keep in sync in the backup set.

## What it excludes, and why

**`edge.db` is never backed up.** This is the one rule the whole layout is
designed around (design D5), not an oversight to work around:

- XMSS is one-time-signature: `edge.db` holds the key index and signer
  state. Restoring a stale `edge.db` after the node has signed anything
  newer silently reuses spent leaves — **forgery**, not recovery. A backup
  that included `edge.db` would create exactly the restore path that must
  never exist.
- The exclusion is **by construction, not convention**: the script carries
  an explicit allow-list of the three databases above and never globs
  `*.db`, so a future new database is not silently swept in either.
- A runtime guard re-checks the list at every run (even `--dry-run`) and
  refuses to start if `edge.db` — or any unsanctioned database, or any
  edge-related source volume — ever enters the list. If it ever fires,
  treat it as a code bug to fix upstream, never as a prompt to disable it.

If `edge_data` is ever lost, there is deliberately no backup to restore
from: revoke and re-issue the affected keys — a key-rotation event, see
[org-key-rotation.md](org-key-rotation.md) and the README
[XMSS key state persistence](../README.md#xmss-key-state-persistence-org-and-edge-keys)
section.

The script also **fails closed** rather than backing up something dubious:

- Missing source volume or missing database → refuses (the migration has
  not run on this node; it will not fall back to the old shared
  `sead_data` volume — a stale shared copy is not a valid source).
- 0-byte database → refuses (the documented orphan state, design D8).
- Checkpoint hard error, failed/0-byte snapshot, or `integrity_check`
  anything but `ok` → aborts with non-zero exit, the unverified partial
  copy is removed, the source is left untouched.

## Where it writes

Each run writes into its own timestamped subdirectory of a **host
directory**:

```
${BACKUP_ROOT}/<UTC timestamp YYYYmmddTHHMMSSZ>
```

- `BACKUP_ROOT` defaults to `/var/backups/sead` and is overridable via the
  environment variable (must be an absolute path), e.g.
  `BACKUP_ROOT=/mnt/usb/backups scripts/backup_databases.sh`.
- The destination is deliberately **outside the repo and outside Docker's
  volume tree** (design D6): a Docker volume dies with `down -v` and is
  awkward to copy off the machine; a host directory can be rsynced,
  snapshotted, or shipped to object storage.
- Timestamps are UTC so they are sortable and stay unique across DST and
  clock changes — two runs can never merge into one directory.
- `--dry-run` runs all pre-flight checks and prints the plan, writing
  nothing (no destination directory is created).

## Running a backup

Requirements: Docker + the `sqlite3` CLI on the host; the stack may be
running. Reading volume mountpoints needs root. From the deployment clone:

```bash
sudo scripts/backup_databases.sh --dry-run   # pre-flight + plan, writes nothing
sudo scripts/backup_databases.sh
```

A successful run prints the destination, one `integrity_check ok` line per
database, and `backup complete`. Treat the snapshot directory as ordinary
operational data — unlike `edge.db`, these three databases are safe to
restore.

There is **no scheduler on the nodes** (no systemd unit, no cron entry):
invocation is manual for now; whether it should be a timer is an open
question in the design doc.

Before the volume migration has run on a node, this script cannot be used
(it reads per-service volumes and fails closed) — the pre-migration
snapshot is the manual copy in
[update-runbook.md](update-runbook.md) step 6.

## Restoring a covered database

Restoring `sead.db`, `sourcedata.db` or `pin-service.db` from a snapshot
is a plain file replacement — stop the stack, copy the snapshot into its
volume, hand it back to the service user, restart:

```bash
docker compose stop
MP=$(docker volume inspect -f '{{ .Mountpoint }}' stardome-sead_sead_core_data)
sudo cp /var/backups/sead/<timestamp>/sead.db "$MP/sead.db"
sudo chown 100:101 "$MP/sead.db"          # syslog:syslog — the service user
sudo sqlite3 "$MP/sead.db" 'PRAGMA integrity_check;'   # expect: ok
docker compose up -d
```

Remove any stale `-wal`/`-shm` sidecars in the volume next to a restored
database (the snapshot is self-contained; old sidecars do not match it).
And the standing rule again: **no snapshot ever contains `edge.db`** — if
edge state is missing, that is a rotation event, not a restore.
