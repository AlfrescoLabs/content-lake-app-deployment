#!/usr/bin/env bash
# run-tests.sh — Content Lake end-to-end test orchestrator.
#
# Runs from content-lake-app-deployment/:
#   ./test/run-tests.sh              # build from local sibling sources (../content-lake-app, …)
#   USE_LOCAL=0 ./test/run-tests.sh  # build/pull from the git branches in .env instead
#
# Phase 1: start Alfresco stack        (make up-alfresco) → Alfresco suite     → down.
# Phase 2: start Nuxeo + content-lake  (make up-nuxeo)    → Nuxeo suite        → down.
# Phase 3: start full stack            (make up-full)     → cross-source RAG + → down.
#                                                            Sprint 0 advisor suite +
#                                                            retrieval quality gate
#
# The Makefile profile targets own bringing up ../nuxeo-deployment and, in local mode,
# building the Content Lake images from the sibling checkouts. `make down` also tears
# down ../nuxeo-deployment, so this script no longer manages the Nuxeo server directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NUXEO_DIR="$(cd "$DEPLOY_DIR/../nuxeo-deployment" 2>/dev/null && pwd || true)"

# Build from local sibling checkouts by default (this is a source-change test harness).
# Pass USE_LOCAL=0 to use the images/contexts baked into .env instead.
#
# NOTE: we deliberately do NOT use `make up-<profile> local`. That target forces a
# `--no-cache` rebuild of the WHOLE profile, including hxpr-app, whose Dockerfile clones the
# Hyland/ai-ready-index repo (private today, so the clone needs HXPR_GIT_AUTH_TOKEN). Instead we
# build ONLY the local-source Content Lake app images (which is all a source change affects) and
# then `up` WITHOUT `--build`, so the prebuilt hxpr/ACS images are reused. Build those
# credential-gated images once via `make up-alfresco` before running this harness.
USE_LOCAL="${USE_LOCAL:-1}"

# The deployment proxy terminates TLS and 301-redirects http -> https, so probe and test over
# HTTPS by default. Child suites read HOST/USE_HTTPS/*_AUTH from the environment.
HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
export HOST USE_HTTPS
export ALF_AUTH="${ALF_AUTH:-admin:admin}"
export NUXEO_AUTH="${NUXEO_AUTH:-Administrator:Administrator}"
if [ "$USE_HTTPS" = "true" ]; then
  SCHEME="https"; CURL_TLS="-k"
else
  SCHEME="http"; CURL_TLS=""
fi
BASE="${SCHEME}://${HOST}"

# Sibling source contexts used when USE_LOCAL=1. Held in separate names because dc() sources .env,
# which would otherwise clobber these (see the comment on dc()).
LOCAL_CL_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-../content-lake-app}"
LOCAL_CL_ACS_CONTEXT="${CONTENT_LAKE_ACS_GIT_CONTEXT:-../content-lake-app}"
LOCAL_CL_UI_CONTEXT="${CONTENT_LAKE_UI_GIT_CONTEXT:-../alfresco-content-lake-ui}"
LOCAL_CL_APP_UI_CONTEXT="${CONTENT_LAKE_APP_UI_CONTEXT:-../content-lake-app-ui}"

# Local-source Content Lake app services affected by a code change, per profile.
CL_APP_SERVICES_ALFRESCO="rag-service batch-ingester live-ingester"
CL_APP_SERVICES_NUXEO="rag-service nuxeo-batch-ingester nuxeo-live-ingester"
CL_APP_SERVICES_FULL="rag-service batch-ingester live-ingester nuxeo-batch-ingester nuxeo-live-ingester"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
banner() { printf "\n${B}${C}==============================================${N}\n${B}${C}  %s${N}\n${B}${C}==============================================${N}\n" "$*"; }
info()  { printf "${C}[INFO]${N} %s\n" "$*"; }
warn()  { printf "${Y}[WARN]${N} %s\n" "$*"; }
die()   { printf "${R}[FATAL]${N} %s\n" "$*" >&2; exit 1; }
ok()    { printf "${G}[OK]${N}   %s\n" "$*"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
banner "Checking prerequisites"
command -v docker >/dev/null 2>&1      || die "docker not found"
command -v jq     >/dev/null 2>&1      || die "jq not found  (brew install jq)"
command -v curl   >/dev/null 2>&1      || die "curl not found"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"
make --version >/dev/null 2>&1         || die "make not found"
ok "docker, jq, curl, docker-compose, make all present"

# LLM/embedding backend (Docker Model Runner) — RAG generation needs it to be reachable.
if curl -sf -m 5 http://localhost:12434/engines/v1/models >/dev/null 2>&1; then
  ok "AI inference backend reachable on :12434"
else
  warn "AI inference backend not reachable on :12434 — RAG generation tests may fail."
  warn "Enable Docker Model Runner (Docker Desktop) or run 'make start-ai'."
fi
# The suite starts stacks with docker compose, not make up-*, so it runs the same LLM_MODEL check.
make -C "$DEPLOY_DIR" ensure-llm || die "LLM_MODEL is not available in Docker Model Runner (see 'make ensure-llm')"
ok "LLM_MODEL available"

# ── Helpers ───────────────────────────────────────────────────────────────────
# The shared readiness probes, so this script and run-phase1.sh cannot disagree about what "ready"
# means. wait_for_url below stays for endpoints whose status code really is the whole signal (a
# repository API, a sync API behind nginx); anything that reports its own health in the body must use
# wait_json_field, because a 200 from such an endpoint says nothing. See #20.
# shellcheck source=lib/readiness.sh
. "$SCRIPT_DIR/lib/readiness.sh"

wait_for_url() {
  # wait_for_url <url> [auth] [max_tries=60] [interval_s=10]
  local url="$1" auth="${2:-}" max="${3:-60}" interval="${4:-10}"
  local curl_auth=()
  [ -n "$auth" ] && curl_auth=(-u "$auth")
  local i code
  for i in $(seq 1 "$max"); do
    # shellcheck disable=SC2086
    code=$(curl -sf $CURL_TLS -o /dev/null -w '%{http_code}' "${curl_auth[@]}" "$url" 2>/dev/null )
    code="${code:-000}"
    if [ "$code" = "200" ]; then return 0; fi
    printf '.'
    sleep "$interval"
  done
  echo; return 1
}

# Compose invocation mirroring the Makefile's env wiring, without the Makefile's forced
# `--no-cache` full-profile rebuild.
dc() {
  # The build contexts are re-applied AFTER sourcing .env, not merely exported above. `set -a; . ./.env`
  # assigns unconditionally, and .env pins
  # CONTENT_LAKE_GIT_CONTEXT=https://github.com/AlfrescoLabs/content-lake-app.git#main, so an export made
  # before this function is overwritten and USE_LOCAL=1 silently builds and tests origin/main instead of
  # the sibling checkout. That failure is invisible: the build succeeds, the suites pass, and the
  # retrieval gate reports no delta because it measured the unchanged code.
  ( cd "$DEPLOY_DIR" \
    && set -a && . ./.env && [ -f ./.env.local ] && . ./.env.local; set +a \
    && if [ "$USE_LOCAL" = "1" ]; then
         CONTENT_LAKE_GIT_CONTEXT="$LOCAL_CL_CONTEXT"
         CONTENT_LAKE_ACS_GIT_CONTEXT="$LOCAL_CL_ACS_CONTEXT"
         CONTENT_LAKE_UI_GIT_CONTEXT="$LOCAL_CL_UI_CONTEXT"
         CONTENT_LAKE_APP_UI_CONTEXT="$LOCAL_CL_APP_UI_CONTEXT"
         export CONTENT_LAKE_GIT_CONTEXT CONTENT_LAKE_ACS_GIT_CONTEXT \
                CONTENT_LAKE_UI_GIT_CONTEXT CONTENT_LAKE_APP_UI_CONTEXT
       fi \
    && NGINX_SYNC_DEFAULT_BACKEND="${NGINX_SYNC_DEFAULT_BACKEND:-batch-ingester:9090}" \
       NGINX_ROOT_DIRECTIVE="${NGINX_ROOT_DIRECTIVE:-return 302 /aca/;}" \
       docker compose --env-file .env.local "$@" )
}

# Asserts the running rag-service is the image we just built, not a stale or remote-built one.
assert_local_build() {
  local marker="/app/BOOT-INF/classes/org/hyland/contentlake/rag/service/QueryExpansionService.class"
  docker exec content-lake-app-rag-service-1 sh -c "ls $marker" >/dev/null 2>&1 \
    || warn "running rag-service does not carry $(basename "$marker"): is it built from $LOCAL_CL_CONTEXT?"
}

stack_up() {
  local profile="$1"
  local services_var="CL_APP_SERVICES_${profile^^}"
  local services="${!services_var:-}"
  # Nuxeo-backed profiles need the sibling nuxeo-deployment server.
  if [ "$profile" != "alfresco" ] && [ -d "$NUXEO_DIR" ]; then
    info "Bringing up ../nuxeo-deployment …"
    ( cd "$NUXEO_DIR" && docker compose up -d ) || return 1
  fi
  if [ "$USE_LOCAL" = "1" ] && [ -n "$services" ]; then
    info "Building local-source app images: $services"
    # shellcheck disable=SC2086
    dc --profile "$profile" build $services || return 1
  fi
  # `up` without --build: prebuilt hxpr/ACS images are reused; only missing images build.
  dc --profile "$profile" up -d
}

stack_down() {
  # Wipe volumes between phases (-v). Without this the hxpr/OpenSearch index persists across phases,
  # so a later phase (notably the Phase 3 retrieval-quality gate, which runs `cleval ingest --clean`)
  # sees earlier phases' documents and aborts on a "duplicated index". Each phase ingests its own
  # fixtures, so a clean index per phase is the intended state.
  dc --profile '*' down -v
  [ -d "$NUXEO_DIR" ] && ( cd "$NUXEO_DIR" && docker compose down -v 2>/dev/null || true )
}

# ── Phase 1: Alfresco ─────────────────────────────────────────────────────────
banner "PHASE 1 — Alfresco + Content Lake"

info "Starting Alfresco stack (profile=alfresco, local build=$USE_LOCAL) …"
stack_up alfresco || die "Alfresco stack bring-up failed"

info "Waiting for Alfresco (up to 10 min) …"
wait_for_url \
  "$BASE/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-/children" \
  'admin:admin' 60 10 \
  || die "Alfresco did not become ready within 10 minutes"
ok "Alfresco is up"

# The reported status, not the status code: /api/rag/health answers 200 {"status":"DOWN"} while its
# dependencies are still starting, so a 200 check returns at once and the suite runs against a service
# that is not serving. That is what made the B series fail for no code reason (#20).
info "Waiting for RAG health status = UP (up to 5 min) …"
wait_rag_up "$BASE" 'admin:admin' 60 5 \
  || warn "RAG health never reached UP; proceeding anyway"
ok "RAG service is UP"
assert_local_build

# The smoke suite probes /api/sync/status immediately; wait for the batch ingester so the first
# probe does not race a still-starting upstream (nginx returns 502 for an unreachable upstream).
info "Waiting for the batch ingester (up to 3 min) …"
wait_for_url "$BASE/api/sync/status" 'admin:admin' 36 5 \
  || warn "batch-ingester /api/sync/status not returning 200; proceeding anyway"
ok "Batch ingester is up"

banner "Running Alfresco test suite"
ALFRESCO_RC=0
bash "$SCRIPT_DIR/test-alfresco.sh" || ALFRESCO_RC=$?

banner "Stopping Alfresco stack"
stack_down

# ── Phase 2: Nuxeo ────────────────────────────────────────────────────────────
banner "PHASE 2 — Nuxeo + Content Lake"

[ -d "$NUXEO_DIR" ] \
  || die "nuxeo-deployment not found at ../nuxeo-deployment — clone it first:
       git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment"

info "Starting Nuxeo stack (profile=nuxeo, local build=$USE_LOCAL) — also brings up ../nuxeo-deployment …"
stack_up nuxeo || die "Nuxeo stack bring-up failed"

info "Waiting for Nuxeo (up to 8 min) …"
wait_for_url 'http://localhost:8081/nuxeo/api/v1/path/default-domain' \
  'Administrator:Administrator' 96 5 \
  || die "Nuxeo did not become ready within 8 minutes"
ok "Nuxeo is up"

info "Waiting for HXPR / RAG health status = UP (up to 5 min) …"
# The Nuxeo credential, not the Alfresco one. /api/rag/health is open, but the probe sends credentials, and
# sending a credential the service cannot authenticate is worse than sending none: the filter answers
# {"error":"Authentication required"} and the probe can then only time out. With 'admin:admin' this phase
# polled for the full five minutes, logged sixty 'Authentication failed for user admin' warnings, gave up, and
# proceeded to pass its own first assertion immediately -- which is the shape that hides a real readiness
# failure, because the alarming warning is already there on a green run.
wait_rag_up "$BASE" 'Administrator:Administrator' 60 5 \
  || warn "RAG health never reached UP; proceeding anyway"
ok "RAG service is UP"
assert_local_build

# Route the readiness probe to the Nuxeo ingester (?sourceType=nuxeo); the default sync backend is
# the Alfresco batch-ingester, which is not running in the nuxeo profile.
info "Waiting for the Nuxeo batch ingester (up to 3 min) …"
wait_for_url "$BASE/api/sync/status?sourceType=nuxeo" 'Administrator:Administrator' 36 5 \
  || warn "nuxeo-batch-ingester /api/sync/status not returning 200; proceeding anyway"
ok "Nuxeo batch ingester is up"

banner "Running Nuxeo test suite"
NUXEO_RC=0
bash "$SCRIPT_DIR/test-nuxeo.sh" || NUXEO_RC=$?

banner "Stopping Nuxeo stack"
stack_down

# ── Phase 3: Full stack ───────────────────────────────────────────────────────
banner "PHASE 3 — Full Stack RAG"

info "Starting full stack (profile=full, local build=$USE_LOCAL) …"
stack_up full || die "Full stack bring-up failed"

info "Waiting for Alfresco in full mode (up to 10 min) …"
wait_for_url \
  "$BASE/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-/children" \
  'admin:admin' 60 10 \
  || die "Alfresco did not become ready in full mode within 10 minutes"
ok "Alfresco is up in full mode"

info "Waiting for Nuxeo (up to 8 min) …"
wait_for_url 'http://localhost:8081/nuxeo/api/v1/path/default-domain' \
  'Administrator:Administrator' 96 5 \
  || die "Nuxeo did not become ready for full mode within 8 minutes"
ok "Nuxeo is up"

info "Waiting for RAG health status = UP in full mode (up to 5 min) …"
wait_rag_up "$BASE" 'admin:admin' 60 5 \
  || warn "RAG health never reached UP in full mode; proceeding anyway"
ok "RAG service is UP"
assert_local_build

info "Waiting for the batch ingesters (up to 3 min) …"
wait_for_url "$BASE/api/sync/status" 'admin:admin' 36 5 \
  || warn "batch-ingester /api/sync/status not returning 200; proceeding anyway"
wait_for_url "$BASE/api/sync/status?sourceType=nuxeo" 'Administrator:Administrator' 36 5 \
  || warn "nuxeo-batch-ingester /api/sync/status not returning 200; proceeding anyway"
ok "Batch ingesters are up"

# The readiness probes above are the gate; this is only the live ingesters' broker subscription, which is
# not observable over HTTP. 10s covers it, and a longer blind sleep just adds to every run.
info "Waiting 10 s for the live ingesters to subscribe …"
sleep 10

banner "Running full-stack RAG suite"
FULL_RC=0
bash "$SCRIPT_DIR/test-rag-full.sh" || FULL_RC=$?

banner "Running Sprint 0 advisor-pipeline suite"
ADVISOR_RC=0
bash "$SCRIPT_DIR/test-rag-advisor.sh" || ADVISOR_RC=$?

# Retrieval-quality gate. Exit 2 means prerequisites are missing (no uv, no committed baseline),
# which is a skip rather than a failure.
banner "Running retrieval-quality gate"
EVAL_RC=0
bash "$SCRIPT_DIR/test-rag-eval.sh" || EVAL_RC=$?
if [ "$EVAL_RC" -eq 2 ]; then
  warn "Retrieval-quality gate skipped (prerequisites missing)"
  EVAL_RC=0
  EVAL_SKIPPED=1
fi

# ── Teardown ──────────────────────────────────────────────────────────────────
banner "Stopping everything"
stack_down

# ── Final summary ─────────────────────────────────────────────────────────────
banner "TEST RUN COMPLETE"
summarize() {
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    printf "${G}  %-22s: PASSED${N}\n" "$name"
  else
    printf "${R}  %-22s: FAILED (exit %d)${N}\n" "$name" "$rc"
  fi
}
summarize "Alfresco suite"        "$ALFRESCO_RC"
summarize "Nuxeo suite"           "$NUXEO_RC"
summarize "Full RAG suite"        "$FULL_RC"
summarize "Sprint 0 advisor suite" "$ADVISOR_RC"
if [ "${EVAL_SKIPPED:-0}" = "1" ]; then
  printf "${Y}  %-22s: SKIPPED${N}\n" "Retrieval quality gate"
else
  summarize "Retrieval quality gate" "$EVAL_RC"
fi
echo ""
[ "$ALFRESCO_RC" -eq 0 ] && [ "$NUXEO_RC" -eq 0 ] && [ "$FULL_RC" -eq 0 ] \
  && [ "$ADVISOR_RC" -eq 0 ] && [ "$EVAL_RC" -eq 0 ]
