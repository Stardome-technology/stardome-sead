#!/usr/bin/env bash
# Validates the Compose files against an env file, without starting anything.
#
# Usage: .github/scripts/check-compose-config.sh [env-file]
#
# The env file defaults to `.env` in the repository root; CI copies
# `.env.example` there first. The script never writes to the env file: each
# "unset" case runs against a temporary copy with one variable removed.
#
# Checks, for the production pair (compose.yaml + compose.production.yaml) and
# for compose.relay.yaml:
#   1. `config --quiet` exits 0 with the env file as is;
#   2. the resolved config has the top-level `name: stardome-sead`;
#   3. no resolved value holds a `#`, the sign of a comment read as a value;
#   4. with each required variable removed, `config --quiet` exits non-zero and
#      its output names the variable.
set -u

cd "$(dirname "$0")/../.."
env_file="${1:-.env}"
if [ ! -f "$env_file" ]; then
  echo "env file not found: $env_file (copy .env.example to .env first)" >&2
  exit 2
fi

production_required="EDGE_ORG_ID EDGE_ID EDGE_SIGNING_KEY EDGE_ORG_SIGNING_KEY SEAD_AUTH_SECRET GOSSIP_ORG_ID GOSSIP_ADVERTISE"
relay_required="GOSSIP_ADVERTISE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# Runs `docker compose` with only the given env file, so variables exported in
# the caller's shell can't mask a missing one.
compose() {
  local file="$1"; shift
  env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME $(for v in $production_required; do printf -- '-u %s ' "$v"; done) \
    docker compose --env-file "$file" "$@"
}

check() {
  local label="$1" required="$2"; shift 2
  local out="$tmp/out" var status

  if compose "$env_file" "$@" config --quiet >"$out" 2>&1; then
    pass "$label: config --quiet exits 0"
  else
    fail "$label: config --quiet exits non-zero"; cat "$out"
  fi

  if compose "$env_file" "$@" config >"$tmp/config.yaml" 2>"$out"; then
    if grep -qx 'name: stardome-sead' "$tmp/config.yaml"; then
      pass "$label: config shows name: stardome-sead"
    else
      fail "$label: config lacks name: stardome-sead"
    fi
    if grep -n '#' "$tmp/config.yaml"; then
      fail "$label: config holds comment text in a value (lines above)"
    else
      pass "$label: config holds no comment text in any value"
    fi
  else
    fail "$label: config exits non-zero"; cat "$out"
  fi

  for var in $required; do
    grep -v "^${var}=" "$env_file" >"$tmp/env.unset"
    compose "$tmp/env.unset" "$@" config --quiet >"$out" 2>&1
    status=$?
    if [ "$status" -ne 0 ] && grep -q "$var" "$out"; then
      pass "$label: with $var unset, exits $status naming it: $(tr '\n' ' ' <"$out")"
    else
      fail "$label: with $var unset, exits $status: $(tr '\n' ' ' <"$out")"
    fi
  done
}

check "production" "$production_required" -f compose.yaml -f compose.production.yaml
check "relay" "$relay_required" -f compose.relay.yaml

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
