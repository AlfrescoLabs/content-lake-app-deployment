#!/usr/bin/env bash
# Resolve the repository ids of both Alfresco instances, then start the rest of the alfresco-2 stack.
#
# With compose.alfresco-2.yaml loaded, rag-service lists both instances as rag.sources[] entries of type
# alfresco, and two entries of one type must each carry an id: the repository id, which is created on the
# first bootstrap. So up-alfresco-2 first starts the two repositories alone, then runs this script, which
#   - reads repository.id from /alfresco/api/discovery inside each container,
#   - compares the ids with ALFRESCO_1_SOURCE_ID / ALFRESCO_2_SOURCE_ID (re-checked on every run, because
#     `make clean` gives both repositories new ids),
#   - asks before writing them to .env.local, and
#   - execs the phase-2 command with both ids exported.
#
# Usage: scripts/resolve-alfresco-source-ids.sh -- <command...>
#   Reads .env/.env.local values from the environment (the Makefile sources them first).
#
# Environment:
#   COMPOSE_ENV_ARGS                      extra docker compose arguments, e.g. "--env-file .env.local"
#   ENV_LOCAL_FILE                        file the ids are written to (default ./.env.local)
#   ALFRESCO_SOURCE_IDS_NONINTERACTIVE=1  never prompt (also the case when no terminal is available)
#   ALFRESCO_SOURCE_IDS_ASSUME_YES=1      answer yes to every prompt, e.g. in CI
#   ALFRESCO_SOURCE_IDS_TTY               where answers are read from (default /dev/tty)
#   ALFRESCO_SOURCE_IDS_TIMEOUT           seconds to wait for each repository to answer (default 600)
#   DOCKER                                docker binary (default docker)

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
err()  { echo -e "${RED}✗ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $*${NC}" >&2; }
say()  { echo -e "$*" >&2; }

if [ "${1:-}" != "--" ] || [ $# -lt 2 ]; then
  err "Usage: $0 -- <command...>"
  exit 2
fi
shift

DOCKER="${DOCKER:-docker}"
ENV_LOCAL_FILE="${ENV_LOCAL_FILE:-./.env.local}"
TTY_IN="${ALFRESCO_SOURCE_IDS_TTY:-/dev/tty}"
DISCOVERY_PATH="/alfresco/api/discovery"

# ── Discovery ─────────────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  err "Neither jq nor python3 is installed; one of them is needed to read the repository ids."
  exit 1
fi

parse_repository_id() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.entry.repository.id // empty' 2>/dev/null
  else
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["entry"]["repository"]["id"])
except Exception:
    pass'
  fi
}

# discover <service> <user:password>: polls until the repository answers, which on a first bootstrap
# takes minutes (both instances start at the same time).
discover() {
  local service="$1" credentials="$2" body id
  local timeout="${ALFRESCO_SOURCE_IDS_TIMEOUT:-600}" delay="${ALFRESCO_SOURCE_IDS_RETRY_DELAY:-5}"
  local deadline=$((SECONDS + timeout)) next_note=$((SECONDS + 30))
  while :; do
    # shellcheck disable=SC2086 # COMPOSE_ENV_ARGS is a list of arguments on purpose
    if body=$("$DOCKER" compose ${COMPOSE_ENV_ARGS:-} --profile alfresco --profile alfresco-2 \
          exec -T "$service" curl -sf -u "$credentials" "http://localhost:8080${DISCOVERY_PATH}" 2>/dev/null); then
      id=$(printf '%s' "$body" | parse_repository_id || true)
      if [[ "$id" =~ ^[A-Za-z0-9-]+$ ]]; then
        printf '%s' "$id"
        return 0
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    if [ "$SECONDS" -ge "$next_note" ]; then
      say "   still waiting for $service to answer $DISCOVERY_PATH..."
      next_note=$((SECONDS + 30))
    fi
    sleep "$delay"
  done
  err "Could not read repository.id from $service ($DISCOVERY_PATH) within ${timeout}s."
  say "   Check that it is healthy: make ps, and docker compose logs $service"
  say "   Then run 'make up-alfresco-2' again (ALFRESCO_SOURCE_IDS_TIMEOUT sets the wait, in seconds)."
  return 1
}

say "${BOLD}Resolving the repository ids of both Alfresco instances...${NC}"
id1=$(discover alfresco "${ALFRESCO_ADMIN_USER:-admin}:${ALFRESCO_ADMIN_PASSWORD:-admin}")
id2=$(discover alfresco-2 "${ALFRESCO_2_INTERNAL_USERNAME:-admin}:${ALFRESCO_2_INTERNAL_PASSWORD:-admin}")
say "   alfresco   repository.id = $id1"
say "   alfresco-2 repository.id = $id2"

if [ "$id1" = "$id2" ]; then
  err "Both Alfresco instances report the same repository id ($id1)."
  say "   The second instance was started from a copy of the first one's volumes, so rag-service cannot"
  say "   tell the two sources apart. Run 'make clean' (destroys all data) and 'make up-alfresco-2' again."
  exit 1
fi

# ── Compare with the configured ids ───────────────────────────────────────────

cur1="${ALFRESCO_1_SOURCE_ID:-}"
cur2="${ALFRESCO_2_SOURCE_ID:-}"

suggested_lines() {
  say "     ALFRESCO_1_SOURCE_ID=$id1"
  say "     ALFRESCO_2_SOURCE_ID=$id2"
}

run_phase_2() {
  export ALFRESCO_1_SOURCE_ID="$id1" ALFRESCO_2_SOURCE_ID="$id2"
  exec "$@"
}

if [ "$cur1" = "$id1" ] && [ "$cur2" = "$id2" ]; then
  ok "ALFRESCO_1_SOURCE_ID and ALFRESCO_2_SOURCE_ID match both repositories"
  run_phase_2 "$@"
fi

interactive=1
if [ "${ALFRESCO_SOURCE_IDS_NONINTERACTIVE:-}" = "1" ]; then
  interactive=0
elif [ "${ALFRESCO_SOURCE_IDS_ASSUME_YES:-}" != "1" ] && ! { exec 3<"$TTY_IN"; } 2>/dev/null; then
  interactive=0
fi

# confirm <question>: 0 on yes
confirm() {
  local answer=""
  if [ "${ALFRESCO_SOURCE_IDS_ASSUME_YES:-}" = "1" ]; then
    say "$1 [y/N] y (ALFRESCO_SOURCE_IDS_ASSUME_YES=1)"
    return 0
  fi
  printf '%b' "${BOLD}$1 [y/N] ${NC}" >&2
  read -r answer <&3 || answer=""
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# set_var <key> <value>: replace an uncommented KEY= (or export KEY=) line, or append one
set_var() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" {
      if (!done) { print key "=" value; done = 1 }
      next
    }
    { print }
    END { if (!done) print key "=" value }
  ' "$ENV_LOCAL_FILE" > "$tmp"
  # Rewrite in place so the file keeps its permissions.
  cat "$tmp" > "$ENV_LOCAL_FILE"
  rm -f "$tmp"
}

write_env_local() {
  if [ -f "$ENV_LOCAL_FILE" ]; then
    cp -p "$ENV_LOCAL_FILE" "$ENV_LOCAL_FILE.bak"
    # Make sure an appended line starts on a line of its own.
    if [ -s "$ENV_LOCAL_FILE" ] && [ "$(tail -c1 "$ENV_LOCAL_FILE" | od -An -c | tr -d ' ')" != '\n' ]; then
      echo >> "$ENV_LOCAL_FILE"
    fi
    say "   Backed up $ENV_LOCAL_FILE to $ENV_LOCAL_FILE.bak"
  else
    : > "$ENV_LOCAL_FILE"
  fi
  set_var ALFRESCO_1_SOURCE_ID "$id1"
  set_var ALFRESCO_2_SOURCE_ID "$id2"
  ok "Wrote ALFRESCO_1_SOURCE_ID and ALFRESCO_2_SOURCE_ID to $ENV_LOCAL_FILE"
}

if [ -z "$cur1" ] && [ -z "$cur2" ] || { [ -z "$cur1" ] && [ "$cur2" = "$id2" ]; } \
    || { [ -z "$cur2" ] && [ "$cur1" = "$id1" ]; }; then
  # Missing ids (typically the first run): safe to use the discovered ones either way.
  say ""
  warn "ALFRESCO_1_SOURCE_ID and/or ALFRESCO_2_SOURCE_ID are not set."
  say "   rag-service lists both Alfresco instances as sources of type alfresco, and two sources of one"
  say "   type must each carry their repository id, or rag-service refuses to start. The ids exist only"
  say "   once each repository has bootstrapped, which it now has. Discovered:"
  suggested_lines
  if [ "$interactive" = "1" ] && confirm "Write these ids to $ENV_LOCAL_FILE?"; then
    write_env_local
  else
    warn "$ENV_LOCAL_FILE left unchanged. Using the discovered ids for this run only."
    say "   To keep them for future runs, add these lines to $ENV_LOCAL_FILE:"
    suggested_lines
  fi
  run_phase_2 "$@"
fi

# Configured ids that do not match the repositories (typically after `make clean`).
say ""
warn "The configured repository ids do not match the running Alfresco instances:"
[ "$cur1" != "$id1" ] && say "     ALFRESCO_1_SOURCE_ID: ${cur1:-<empty>} -> $id1"
[ "$cur2" != "$id2" ] && say "     ALFRESCO_2_SOURCE_ID: ${cur2:-<empty>} -> $id2"
say "   A repository gets a new id when its volumes are recreated, e.g. after 'make clean'. With stale ids"
say "   rag-service would scope permissions to repositories that no longer exist, so documents of these"
say "   instances would not be found."
if [ "$interactive" = "1" ] && confirm "Overwrite them in $ENV_LOCAL_FILE?"; then
  write_env_local
  run_phase_2 "$@"
fi

err "Not starting the rest of the stack with stale repository ids."
say "   Edit $ENV_LOCAL_FILE so that it contains:"
suggested_lines
say "   (or remove both lines), then run 'make up-alfresco-2' again."
exit 1
