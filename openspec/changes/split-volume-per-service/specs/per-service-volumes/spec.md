## Purpose

Isolates the XMSS key index from the other databases so no routine operation can destroy it, and makes
a missed migration fail loudly instead of silently reusing spent key indices.

## ADDED Requirements

### Requirement: Each service has its own volume

Each service that persists a database SHALL mount a volume dedicated to it, rather than sharing one
volume with the others.

#### Scenario: Services do not share a data volume
- **WHEN** the resolved production compose configuration is inspected
- **THEN** `sead-core`, `edge-service`, `pin-service` and `source-data-service` each mount a distinct
  volume at `/data`

#### Scenario: Database files are separated
- **WHEN** the stack runs
- **THEN** `edge.db`, `sead.db`, `pin-service.db` and `sourcedata.db` each live in their own volume

### Requirement: The edge key index volume is never deleted

The volume holding `edge.db` SHALL be declared `external: true`, so Compose never creates or removes it.

#### Scenario: Missing volume stops the stack
- **WHEN** `up` runs on a node where the `edge.db` volume does not exist
- **THEN** Compose fails with an error naming the missing external volume
- **AND** edge-service does not start

#### Scenario: down -v does not remove it
- **WHEN** `docker compose down -v` is run
- **THEN** the `edge.db` volume survives

### Requirement: The migration preserves the key index

The migration from the shared volume SHALL checkpoint each database, copy the database with its WAL and
SHM files, verify the copy, and only then rename the old files.

#### Scenario: WAL contents are preserved
- **WHEN** the migration copies a database whose WAL holds committed transactions
- **THEN** the copied database contains those transactions
- **AND** a row count per table matches the source

#### Scenario: Copy is verified before success
- **WHEN** the migration finishes copying a database
- **THEN** `PRAGMA integrity_check` on the copy returns `ok`
- **AND** the migration reports failure if it does not

#### Scenario: Old files are renamed, not deleted
- **WHEN** the migration completes successfully
- **THEN** the old `edge.db` in the shared volume is renamed, not removed
- **AND** a rollback to the old compose fails because edge-service finds no `edge.db` at the expected
  path

#### Scenario: Migration is idempotent
- **WHEN** the migration is run twice
- **THEN** the second run detects the already-migrated state and makes no changes

#### Scenario: Dry run changes nothing
- **WHEN** the migration is run with `--dry-run`
- **THEN** it prints the plan and modifies no file or volume

### Requirement: The backup excludes the edge key index

The backup script SHALL back up `sead.db`, `sourcedata.db` and `pin-service.db`, and SHALL NOT back up
`edge.db`.

#### Scenario: edge.db is not in the backup
- **WHEN** the backup script runs
- **THEN** the backup contains no `edge.db` file

#### Scenario: Backup is verified
- **WHEN** each database is backed up
- **THEN** `PRAGMA integrity_check` on the backup copy returns `ok`

#### Scenario: Backup destination is outside Docker
- **WHEN** the backup completes
- **THEN** the files are written to a host directory, not a Docker volume

### Requirement: Losing the key index requires a key rotation

The documentation SHALL state that losing `edge.db`, or restoring an old copy of it, requires rotating
the edge key, and SHALL warn against `docker compose down -v`.

#### Scenario: Documentation states the consequence
- **WHEN** the volume documentation is read
- **THEN** it states that a lost or stale `edge.db` requires an edge key rotation
- **AND** it warns that `docker compose down -v` destroys data volumes

### Requirement: The update runbook reconciles local changes first

The update procedure SHALL begin by reconciling any uncommitted local compose modifications before
pulling, so the pull does not conflict.

#### Scenario: Local changes are handled before pull
- **WHEN** an operator follows the update runbook on a node with local compose modifications
- **THEN** the first step reconciles or discards those modifications
- **AND** the pull succeeds
