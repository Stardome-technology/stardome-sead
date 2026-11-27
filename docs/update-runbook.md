# Edge Node Update Runbook — Shared Volume → Per-Service Volumes

Manual update procedure for an **already-deployed edge node**: it moves the
databases off the old shared `stardome-sead_sead_data` volume onto the
per-service volumes (`sead_core_data`, `edge_data`, `pin_data`,
`sourcedata_data`) described in the README
([Volumes](../README.md#volumes)).

There is **no systemd unit and no update script** on the nodes — every step
below is run by hand, in this order. The design rationale for each gate is
`openspec/changes/split-volume-per-service/design.md` (D1–D8).

> **Fresh node?** A node that never ran the old shared-volume layout has
> nothing to migrate: create the external `edge_data` volume
> (`docker volume create stardome-sead_edge_data`) and `docker compose up -d`.
> Steps 5–7 below do not apply.

The sequence is: **verify working tree → verify keys → pull → stop → snapshot →
create volumes → migrate → `up -d` → verify.**

## Prerequisites

- Docker + Docker Compose plugin, and the `sqlite3` CLI on the host (the
  migration script checkpoints and verifies with it).
- Commands run from the deployment clone (e.g. `~/stardome-sead`). Steps that
  read the Docker volume tree (`/var/lib/docker/volumes/...`) need root —
  prefix them with `sudo`.
- The compose pair in use is `compose.yaml` + `compose.production.yaml`
  (`.env` sets `COMPOSE_FILE`), same as the README.

## 1. Verify the working tree before pulling

Nodes carry a stale dirty flag on the compose files (`M compose.yaml`,
`M compose.production.yaml`) that is **not** local work — the content is
byte-identical to `origin/main`. Verify first, then act on what is actually
there:

```bash
git fetch origin
git diff --quiet origin/main -- compose.yaml compose.production.yaml \
  && git checkout -- compose.yaml compose.production.yaml \
  || echo "STOP: local compose differs from origin/main — inspect before pulling"
```

- Diff empty (the expected case): the `git checkout --` clears the stale flag
  with no content change and the pull will be clean.
- Diff **not** empty: someone hand-edited the compose files. Inspect
  `git diff origin/main -- compose.yaml compose.production.yaml` and
  reconcile — commit or `git stash` the real change, or deliberately discard
  it with `git checkout --`. Do not blind-stash; there is usually nothing to
  stash.

Two related facts:

- **`?? keys/` in `git status` is expected** on a pre-#39 checkout and must
  never be cleaned. `keys/` is gitignored on `origin/main`; the marker
  disappears after the pull. Deleting the directory destroys the edge signing
  key. Never run `git clean` here.
- Do **not** touch `compose.relay.yaml`; this change does not involve it.

## 2. Confirm the key files exist

The secrets prerequisite is already satisfied on deployed nodes — verify it,
do not re-create it:

```bash
ls -l keys/edge_sign.hex keys/org_sign.hex keys/org_pub.hex
```

Expect mode `0400`, owned `10001:10001` (the image user in
`scripts/image-user.env`), and `.env` pointing
`EDGE_SIGNING_KEY_FILE`, `EDGE_ORG_SIGNING_KEY_FILE` and
`EDGE_ORG_PUBLIC_KEY_FILE` at those files.

## 3. Pull

```bash
git pull
docker compose -f compose.yaml -f compose.production.yaml pull
```

Clean after step 1. If it still conflicts, stop — step 1 missed something.

`compose.production.yaml` pins each image by digest. The `pull` fetches the
digests the new commit pins while the stack is still up, so a registry or
network failure shows here, before step 5 stops anything, and the stop lasts
only as long as the migration.

## 4. Record the pre-update edge key index

`edge.db` is key material: losing it or restoring a stale copy is a
**key-rotation event**, so the post-migration check needs a baseline. While
the stack is still up, note the last used signer indices:

```bash
sudo sqlite3 "$(docker volume inspect -f '{{ .Mountpoint }}' stardome-sead_sead_data)/edge.db" \
  'SELECT * FROM key_index;'
```

Save the output.

## 5. Stop the stack

```bash
docker compose stop
```

**Never `docker compose down -v`** on a deployed node: `-v` deletes the
project-scoped volumes (`sead_core_data`, `pin_data`, `sourcedata_data`) with
every database in them. `edge_data` survives `-v` only because it is external,
but there is no routine operation that needs `-v`. Plain `stop` is enough —
the migration's pre-flight only requires that no project containers are
running.

## 6. Snapshot the old shared volume (backup before migrate)

`scripts/backup_databases.sh` reads the **per-service** volumes and fails
closed before the migration (a stale shared copy is not a valid backup source
once services write per-service), so the pre-migration snapshot is a manual
copy of the quiesced shared volume:

```bash
SRC=$(docker volume inspect -f '{{ .Mountpoint }}' stardome-sead_sead_data)
DEST=/var/backups/sead/pre-migration-$(date -u +%Y%m%dT%H%M%SZ)
sudo mkdir -p "$DEST" && sudo cp -a "$SRC"/. "$DEST"/
```

Copy `edge.db` **with its `-wal` and `-shm` sidecars** (the `cp -a` above does)
— the WAL can hold committed transactions larger than the main file. Treat the
snapshot as key material (mode `0400`, restricted access). After this node has
signed anything newer, **never restore `edge.db` from it** — that is a
key-rotation event, not a recovery step.

## 7. Create the destination volumes

The migration script never creates (or removes) volumes; all four
destinations must exist first:

```bash
docker volume create stardome-sead_edge_data      # external in compose — Compose will never create it
docker volume create stardome-sead_sead_core_data
docker volume create stardome-sead_pin_data
docker volume create stardome-sead_sourcedata_data
```

`docker volume create` is idempotent. Note on `stardome-sead_pin_data`: on the
lab edges it already exists as a **stale orphan** holding a 0-byte
`pin-service.db`. That is expected — the migration overwrites it with the real
database. The 0-byte file must never be used as a restore source.

## 8. Run the migration

```bash
sudo scripts/migrate_volumes.sh --dry-run   # pre-flight + plan, touches nothing
sudo scripts/migrate_volumes.sh
```

What it does (design D2–D4): checkpoints each WAL, copies `db` + `-wal` +
`-shm` to the per-service volume, verifies with `PRAGMA integrity_check` and
per-table row counts, re-owns everything to the image user in
`scripts/image-user.env` (`10001:10001`), and only then renames the
old `edge.db` to `edge.db.migrated` — nothing is deleted. It is idempotent (a
second run is a no-op) and fails closed: any verification failure aborts
**before** the rename with the source volume intact.

## 9. Start the stack

```bash
docker compose up -d
```

If `up` fails with `external volume "stardome-sead_edge_data" not found`, step
7 was skipped. That fail-loud is intended — an empty `edge.db` would make the
edge sign from index 0 and reuse spent XMSS leaves. Create the volume, never
paper over the error.

## 10. Verify

- **Services healthy:** `docker compose ps` shows the stack up and healthy
  (edge-service, sead-core, pin-service, source-data-service, gateway,
  gossip-node).
- **Databases intact** on the new volumes:

  ```bash
  for db in sead_core_data/sead.db edge_data/edge.db pin_data/pin-service.db sourcedata_data/sourcedata.db; do
      vol=${db%%/*}; f=${db##*/}
      mp=$(docker volume inspect -f '{{ .Mountpoint }}' "stardome-sead_${vol}")
      printf '%-28s ' "$db"; sudo sqlite3 "$mp/$f" 'PRAGMA integrity_check;'
  done
  ```

  Each must print `ok`. Spot-check row counts against the source (the
  migration already compared them table by table).
- **Key index moved forward, never backward:** the first signature after the
  update must use an index **greater** than the value recorded in step 4. If
  it is equal or lower, stop the edge — that is leaf reuse, treat it as a
  rotation event (see [org-key-rotation.md](org-key-rotation.md)).
- **Old shared volume retained:** `stardome-sead_sead_data` (now holding
  `edge.db.migrated` and copies of the others) is deliberately **not**
  removed. It is the only recovery path — leave it in place until everything
  above has been verified for a while.

## 11. After the update

- **Routine backups** now use the script: `scripts/backup_databases.sh`
  checkpoints and snapshots `sead.db`, `sourcedata.db` and `pin-service.db`
  into `BACKUP_ROOT` (default `/var/backups/sead`, one timestamped
  subdirectory per run) and verifies each copy. It **excludes `edge.db` by
  construction** — restoring a stale `edge.db` is silent forgery, so no
  routine backup may contain it. Full backup documentation:
  [backup-runbook.md](backup-runbook.md).
- **Orphan cleanup (optional, manual):** per design D8 nothing automatic ever
  removes volumes. Once the migration is verified, any leftover stale volume
  (e.g. a pre-existing orphan holding only a 0-byte database) can be removed
  by hand with `docker volume rm <name>` — operator's discretion, never part
  of the runbook's required steps.

## Rollback

- **Migration aborted:** nothing was renamed; the source volume is intact. Fix
  the reported problem and re-run, or revert the compose files to the previous
  revision (`git checkout <prev> -- compose.yaml compose.production.yaml`) and
  `docker compose up -d` — the old shared layout still has everything.
- **After a successful migration:** rolling back to the old compose fails
  loudly (edge-service finds no `edge.db` in `sead_data` — it was renamed to
  `edge.db.migrated`, by design). Recovery is manual: rename
  `edge.db.migrated` back inside `sead_data`, or restore from the step-6
  snapshot — and remember that restoring any `edge.db` older than the node's
  last signature is a key-rotation event, not a rollback.
