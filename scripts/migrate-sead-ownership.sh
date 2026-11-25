#!/bin/sh
# migrate-sead-ownership.sh — one-shot root migration of existing SEAD state to
# the canonical image identity declared in image-user.env
# (used when every service moves to the non-root image user).
#
# WHY: live state on nodes is owned either by the legacy Alpine
# `-S` user (uid 100 / gid 101 — sead-core and pin-service today) or by root
# (gossip-node runs as root; its identity key is 0:0 0600). Both must be
# relabelled to $SEAD_UID:$SEAD_GID before the non-root images start.
#
# HOW: run ONCE as root BEFORE the non-root stack starts.
# Idempotent by construction: only files still owned by a known legacy UID are
# touched, so a second run is a no-op exit 0. Files owned by an unexpected
# third UID are reported and left alone (operator decides — never blind-chown
# state of unknown provenance).
#
# PEERID EVIDENCE: the gossip identity key checksum is logged
# before and after the run and must be identical (chown never rewrites
# content; a mismatch means something else touched the file). The full
# before/after PeerId capture is a separate check — this script provides the
# checksum half of that evidence.
#
# Usage (host, as root):
#   sudo scripts/migrate-sead-ownership.sh [PATH ...]
# With no PATHs the default path list below is used.
#
# Usage (root helper via docker, when the host shell is not root):
#   docker run --rm -u 0 \
#     -v "$PWD:/src:ro" \
#     -v sead_sead_data:/mnt/sead_data \
#     -v "$HOME/.sead/gossip-keys:/mnt/gossip-keys" \
#     alpine:3.20 \
#     sh /src/scripts/migrate-sead-ownership.sh /mnt/sead_data /mnt/gossip-keys
#
# Options:
#   --dry-run                     print planned chowns, change nothing
#   --legacy-uids "100 0"         override the legacy UID set to relabel
#   -h, --help
#
# Environment seams (tests / unusual layouts):
#   IMAGE_USER_ENV               path to image-user.env (default: repo root)
#   SEAD_DATA_PATH               host path of the sead_data volume contents
#   SEAD_DATA_VOLUME             docker volume name used to auto-detect the
#                                above (default: sead_sead_data)
#   GOSSIP_IDENTITY_DIR          host dir holding the gossip identity key
#                                (compose default: ~/.sead/gossip-keys)
#   GOSSIP_IDENTITY_KEY_FILE     key file (default: $GOSSIP_IDENTITY_DIR/gossip-identity.key)
#   SEAD_KEYS_DIR                one-shot tool --out-file output dir
#                                (default: ~/.sead/keys)
#   SEAD_KEY_INDEX_DB            gen-bootstrap --key-index-db file when it
#                                lives OUTSIDE the default dirs below
#                                (default: empty — a db inside $SEAD_KEYS_DIR
#                                or the sead_data volume is already covered
#                                by their directory scans)
#   LEGACY_UIDS                  space-separated UIDs to relabel (default: 100 0)
#   CHOWN_CMD / STAT_CMD / SHA_CMD
#                                injectable commands (lets tests run the full
#                                logic unprivileged; default chown/stat/sha256sum)
#
# DEFAULT PATHS (extensible flat list of paths, no logic — it includes
# the one-shot tool image outputs):
#   1. $SEAD_DATA_PATH       shared sead_data volume contents (databases; a
#                            --key-index-db at the documented
#                            /data/org-key-index.db convention lives here)
#   2. $GOSSIP_IDENTITY_DIR  gossip identity key path — the dir holding the
#                            identity key file gossip-identity.key
#                            ($GOSSIP_IDENTITY_KEY_FILE)
#   3. $SEAD_KEYS_DIR        one-shot tool --out-file output dir
#   4. $SEAD_KEY_INDEX_DB    per-file path for a key-index db elsewhere
#
# ONE-SHOT TOOL IMAGES and what they write on disk:
#   keygen        stdout only — nothing to migrate
#   gen-token     --out-file <path> (default stdout); keep outputs under
#                 $SEAD_KEYS_DIR or pass the operator-chosen dir as a PATH
#   gen-bootstrap --out-file <path> (default stdout) AND --key-index-db
#                 <path> — persistent SQLite XMSS signer state that must
#                 survive across runs (docs/bootstrap-genesis.md convention
#                 --key-index-db /data/org-key-index.db); a root-owned db
#                 breaks later runs as $SEAD_UID
#   p2p-bridge    stateless HTTP bridge — writes no files
#
# Missing default paths are skipped gracefully ([skip] line; run still exits 0).
#
# POSIX sh on purpose: the helper may run inside an alpine container where
# bash is not installed. Paths containing whitespace are not supported by the
# default list; pass such paths as positional arguments.
#
# Copied from stardome-sead-private at tag v0.1.0 (commit ec5f8a4), with
# comments and log text reworded to drop internal references; no command
# changed. Do not edit this copy here: change the source and copy it again.
# The header sits below the help text, since --help prints lines 2-86.
# In this repository, image-user.env sits next to this script: pass
# IMAGE_USER_ENV=scripts/image-user.env (see the README, "Moving a node to
# the v0.1.0 user").

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

usage() {
    sed -n '2,86p' "$0" | sed 's/^# \{0,1\}//'
}

# --- target identity: sourced from image-user.env, never hard-coded ---
IMAGE_USER_ENV="${IMAGE_USER_ENV:-$(dirname "$SCRIPT_DIR")/image-user.env}"
if [ ! -f "$IMAGE_USER_ENV" ]; then
    echo "ERROR: image-user.env not found at $IMAGE_USER_ENV (set IMAGE_USER_ENV)" >&2
    exit 1
fi
SEAD_UID="$(sed -n 's/^[[:space:]]*SEAD_UID=//p' "$IMAGE_USER_ENV" | tail -n1)"
SEAD_GID="$(sed -n 's/^[[:space:]]*SEAD_GID=//p' "$IMAGE_USER_ENV" | tail -n1)"
case "$SEAD_UID$SEAD_GID" in
    *[!0-9]*|"") echo "ERROR: SEAD_UID/SEAD_GID missing or non-numeric in $IMAGE_USER_ENV" >&2; exit 1 ;;
esac
TARGET="$SEAD_UID:$SEAD_GID"

# --- tunables ---
DRY_RUN=0
LEGACY_UIDS="${LEGACY_UIDS:-100 0}"   # legacy owners: Alpine -S sead (100) + root (0)
CHOWN_CMD="${CHOWN_CMD:-chown}"
STAT_CMD="${STAT_CMD:-stat}"
SHA_CMD="${SHA_CMD:-sha256sum}"

GOSSIP_IDENTITY_DIR="${GOSSIP_IDENTITY_DIR:-$HOME/.sead/gossip-keys}"
GOSSIP_IDENTITY_KEY_FILE="${GOSSIP_IDENTITY_KEY_FILE:-$GOSSIP_IDENTITY_DIR/gossip-identity.key}"
SEAD_KEYS_DIR="${SEAD_KEYS_DIR:-$HOME/.sead/keys}"
SEAD_KEY_INDEX_DB="${SEAD_KEY_INDEX_DB:-}"

# --- argument parsing ---
PATHS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --legacy-uids) shift; LEGACY_UIDS="${1:?--legacy-uids needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; PATHS="$PATHS $*" ;;
        -*) echo "ERROR: unknown option $1 (see --help)" >&2; exit 1 ;;
        *) PATHS="$PATHS $1"; shift ;;
    esac
done

# --- default path list (see DEFAULT PATHS above) ---
if [ -z "$PATHS" ]; then
    if [ -z "${SEAD_DATA_PATH:-}" ] && command -v docker >/dev/null 2>&1; then
        SEAD_DATA_PATH="$(docker volume inspect "${SEAD_DATA_VOLUME:-sead_sead_data}" \
            -f '{{.Mountpoint}}' 2>/dev/null || true)"
    fi
    if [ -n "${SEAD_DATA_PATH:-}" ]; then
        PATHS="$SEAD_DATA_PATH"
    fi
    [ -d "$GOSSIP_IDENTITY_DIR" ] && PATHS="$PATHS $GOSSIP_IDENTITY_DIR"
    [ -d "$SEAD_KEYS_DIR" ] && PATHS="$PATHS $SEAD_KEYS_DIR"
    [ -n "$SEAD_KEY_INDEX_DB" ] && [ -e "$SEAD_KEY_INDEX_DB" ] && PATHS="$PATHS $SEAD_KEY_INDEX_DB"
fi
if [ -z "$PATHS" ]; then
    echo "ERROR: no paths to migrate. Pass PATHs or set SEAD_DATA_PATH / GOSSIP_IDENTITY_DIR (see --help)." >&2
    exit 1
fi

log() { printf '%s\n' "$*"; }

key_checksum() {
    # Log path + checksum so before/after evidence can be diffed.
    [ -f "$GOSSIP_IDENTITY_KEY_FILE" ] || return 0
    log "[key] checksum ($1): $("$SHA_CMD" "$GOSSIP_IDENTITY_KEY_FILE")"
}

in_legacy_set() {
    for u in $LEGACY_UIDS; do
        [ "$1" = "$u" ] && return 0
    done
    return 1
}

if [ "$DRY_RUN" -eq 1 ]; then
    log "[mode] dry-run (nothing will be changed)"
elif [ "$(id -u 2>/dev/null || echo 0)" != "0" ]; then
    log "[warn] not running as root — chown will fail unless CHOWN_CMD is injected"
fi

log "[target] $TARGET (from $IMAGE_USER_ENV)"
log "[legacy] relabelling files owned by UID(s): $LEGACY_UIDS"
key_checksum before

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT INT TERM

changed=0
scanned=0
foreign=0
missing=0

for p in $PATHS; do
    if [ ! -e "$p" ]; then
        log "[skip] path does not exist: $p"
        missing=$((missing + 1))
        continue
    fi
    find "$p" >"$LIST"
    while IFS= read -r f; do
        scanned=$((scanned + 1))
        owner="$("$STAT_CMD" -c '%u %g' "$f")"
        uid="${owner%% *}"
        gid="${owner##* }"
        if [ "$uid" = "$SEAD_UID" ] && [ "$gid" = "$SEAD_GID" ]; then
            continue  # already migrated — this is what makes run N+1 a no-op
        fi
        if in_legacy_set "$uid"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[dry-run] would chown $uid:$gid -> $TARGET : $f"
            else
                "$CHOWN_CMD" -h "$TARGET" "$f"
                log "[chown] $uid:$gid -> $TARGET : $f"
            fi
            changed=$((changed + 1))
        else
            log "[foreign] left alone (owner $uid:$gid not a known legacy owner): $f"
            foreign=$((foreign + 1))
        fi
    done <"$LIST"
done

key_checksum after

log "[summary] scanned=$scanned relabelled=$changed already_migrated=$((scanned - changed - foreign)) foreign=$foreign missing_paths=$missing"
if [ "$foreign" -gt 0 ]; then
    log "[summary] $foreign file(s) have unexpected owners and were NOT touched — review them manually."
fi
log "[done] migration complete; restart the stack and verify the PeerId is unchanged."
exit 0
