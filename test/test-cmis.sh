#!/usr/bin/env bash
# test-cmis.sh - end-to-end proof that the CMIS connector plugin ingests from a real repository (#125).
#
# Ingests from the running Alfresco's own CMIS endpoint, the only real CMIS 1.1 server this stack already
# has, and the place where the two things unit tests cannot show are visible: that the browser binding
# works against a live repository, and that a document restricted in the source is not retrievable by a
# user its ACL excludes.
#
# Opt-in, and deliberately not a phase of run-tests.sh, for the same reasons as test-connector.sh:
# the 'connector' profile is opt-in, and wiring it into every run would make the whole suite depend on
# a Maven build of a project outside the reactor.
#
# What this suite deliberately does NOT do. Each of these cost minutes per run and proved something that
# was already proved elsewhere, which is how a useful suite turns into an expensive one:
#
#   - It does not rebuild the connector jar when one is already built. The jar is a build artefact, and
#     rebuilding it (installing content-lake-spi into a container-local repository first) spends two to
#     four minutes re-deriving what `mvn package` produced. Pass BUILD_JAR=true to force it.
#   - It does not run the native Alfresco adapter over the same folder to compare document sets. That is
#     a second full ingest, embeddings included, to learn a number the Alfresco REST API answers in one
#     call: how many documents the folder holds. test-alfresco.sh already covers the native path.
#   - It does not wait for the repository (AFTS) index. Only the native adapter's discovery queries it;
#     CMIS traversal reads the folder directly, so that wait bought nothing here.
#   - It does not poll for minutes. The permission filter picks up a new source within its 30-second
#     discovery window, so a document that is not retrievable inside a minute will not become so.
#
# It recreates rag-service with CMIS as its ONLY caller authentication, blanking the Alfresco and Nuxeo URLs,
# and restores it in cleanup. That is what makes the authentication assertions mean something: with those two
# configured, a caller who happens to exist in Alfresco authenticates there and the assertion would prove
# Alfresco authentication rather than CMIS. The consequence is that this suite must NOT run concurrently with
# the Alfresco or Nuxeo suites, because for the duration of that block no caller of either can sign in.
#
# Prerequisites:
#   - the alfresco (or full/demo) base stack already up and healthy
#   - the AI backend on :12434, since ingestion embeds
#   - Docker, curl, jq, unzip
#   - a built jar under ../content-lake-app/plugins/cmis-connector/target/, or BUILD_JAR=true
#
# Usage:
#   CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#   RAG_AUTH=admin:admin ./test/test-cmis.sh
#
# Environment variables:
#   CONNECTOR_SYNC_USERNAME / CONNECTOR_SYNC_PASSWORD  Sync API credentials (required, no defaults)
#   ALF_AUTH        Alfresco credentials, user:password (default: admin:admin)
#   RAG_AUTH        Credentials for the RAG service (default: admin:admin)
#   HOST            Target host (default: localhost)
#   USE_HTTPS       "true" to use https and pass -k to curl (default: true, as the proxy redirects)
#   APP_SOURCE      Path to the content-lake-app checkout (default: ../content-lake-app)
#   BUILD_JAR       "true" to build the connector jar even when one exists (default: false)
#   POLL_DEADLINE_S Seconds to wait for a document to become retrievable (default: 60)
#   KEEP_RUNNING    "true" to leave the service, the jar and the fixtures in place (default: false)

set -uo pipefail

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
RAG_AUTH="${RAG_AUTH:-admin:admin}"
APP_SOURCE="${APP_SOURCE:-../content-lake-app}"
BUILD_JAR="${BUILD_JAR:-false}"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-60}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
SYNC_USER="${CONNECTOR_SYNC_USERNAME:?CONNECTOR_SYNC_USERNAME is required}"
SYNC_PASS="${CONNECTOR_SYNC_PASSWORD:?CONNECTOR_SYNC_PASSWORD is required}"
SYNC_AUTH="${SYNC_USER}:${SYNC_PASS}"

if [ "$USE_HTTPS" = "true" ]; then
  BASE="https://${HOST}"; CURL_OPTS="-k"
else
  BASE="http://${HOST}"; CURL_OPTS=""
fi
ALF_BASE="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
NATIVE_SYNC="${BASE}/api/sync"
RAG_URL="${BASE}/api/rag"
# The connector ingester is not behind the proxy: it is opt-in, so no base deployment routes it.
INGESTER="http://${HOST}:9096"
# What the connector talks to. The service name, not the proxy: this URL is resolved inside the stack
# network, and going through the proxy would add TLS the connector would have to be told to trust.
CMIS_ENDPOINT="http://alfresco:8080/alfresco/api/-default-/public/cmis/versions/1.1/browser"

LOCAL_APP_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-$APP_SOURCE}"
CONNECTOR_DIR="${APP_SOURCE}/plugins/cmis-connector"
JAR_NAME="cmis-connector-1.0.0.jar"
BUILT_JAR="${CONNECTOR_DIR}/target/${JAR_NAME}"
SOURCE_TYPE="cmis"
FIXTURE_COUNT=4
# Host-reachable CMIS, for reading a fixture's own ACL. Not the same URL the connector and rag-service use:
# theirs resolves inside the stack network, this one goes through the proxy.
CMIS_BROWSER_HOST="${BASE}/alfresco/api/-default-/public/cmis/versions/1.1/browser"

TMPDIR_DATA="$(mktemp -d)"
LOG="test-results-cmis-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
warn()    { printf "${Y}[WARN]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

BASE_PROFILE="${BASE_PROFILE:-alfresco}"
dc() {
  local env_args=()
  [ -f ./.env.local ] && env_args=(--env-file .env.local)
  docker compose "${env_args[@]}" --profile "$BASE_PROFILE" --profile connector "$@"
}

FOLDER_ID=""
GROUP_ID=""
RAG_RECONFIGURED=false
cleanup() {
  rm -rf "$TMPDIR_DATA"
  if [ "$KEEP_RUNNING" = "true" ]; then
    info "KEEP_RUNNING=true: the service, ./connectors/${JAR_NAME} and the Alfresco fixtures are left in place"
    info "rag-service is also left with CMIS as its only authentication path, so no Alfresco or Nuxeo"
    info "caller can sign in until it is recreated without RAG_SECURITY_CMIS_* and with the two URLs back"
    return
  fi
  info "Removing the connector service and its jar"
  dc rm -sf plugin-batch-ingester >/dev/null 2>&1
  rm -f "connectors/${JAR_NAME}"
  if [ -n "$FOLDER_ID" ]; then
    curl -s $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X DELETE \
      "$ALF_BASE/nodes/${FOLDER_ID}?permanent=true" 2>/dev/null
  fi
  if [ -n "$GROUP_ID" ]; then
    curl -s $CURL_OPTS -o /dev/null -u "$ALF_AUTH" -X DELETE "$ALF_BASE/groups/${GROUP_ID}" 2>/dev/null
  fi
  # rag-service belongs to the base stack and this suite reconfigured it, so it is put back as it was.
  # Without this, a stack left running has no Alfresco or Nuxeo credential authority at all: every caller of
  # every other suite would 401, which reads as a broken stack rather than as this suite's leftovers.
  if [ "$RAG_RECONFIGURED" = "true" ]; then
    info "Restoring rag-service with its Alfresco and Nuxeo authentication back"
    ( unset RAG_SECURITY_CMIS_ENABLED RAG_SECURITY_CMIS_URL RAG_SECURITY_CMIS_REPOSITORY_ID \
            ALFRESCO_URL NUXEO_URL
      dc up -d --no-deps --force-recreate rag-service >/dev/null 2>&1 )
  fi
}
trap cleanup EXIT

for tool in docker curl jq unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 2; }
done
[ -d "$CONNECTOR_DIR" ] || { echo "CMIS connector not found at $CONNECTOR_DIR (set APP_SOURCE)"; exit 2; }

# ── Fixtures in Alfresco ───────────────────────────────────────────────────────
# Sentinel phrases scoped to this run, so an assertion cannot pass on a document a previous run left
# behind. Distinctive wording, because retrieval is semantic.
RUN_TAG="cmis-$(date +%Y%m%d-%H%M%S)-$$"
FOLDER_NAME="cmis-e2e-${RUN_TAG}"
section "Fixtures"

cat > "${TMPDIR_DATA}/harbour-survey.txt" <<EOF
Harbour survey ${RUN_TAG}.
The dredging of the outer channel at Skagen removed forty-one thousand cubic metres of silt during the
survey period, against a permitted maximum of fifty thousand.
EOF
cat > "${TMPDIR_DATA}/kiln-maintenance.md" <<EOF
# Kiln maintenance ${RUN_TAG}

The refractory lining of kiln four was relined with magnesia-chrome brick after the annual inspection
found spalling across the burning zone.
EOF
cat > "${TMPDIR_DATA}/restricted-tender.txt" <<EOF
Restricted tender ${RUN_TAG}.
The sealed bid for the Frederikshavn quay extension was priced at nineteen million kroner and must not
be disclosed before the award date.
EOF
# The group-grant fixture. Its distinguishing phrase is "Hirtshals pontoon", unique to this document rather
# than the run tag every fixture carries: the absence assertion below would otherwise be unfalsifiable, since
# any readable fixture would satisfy a match on the shared tag.
cat > "${TMPDIR_DATA}/group-granted-berth.txt" <<EOF
Berth allocation ${RUN_TAG}.
The Hirtshals pontoon mooring was reassigned to the inshore fleet after the winter storm damage survey,
with the reallocation recorded against the harbour master's standing order.
EOF

FOLDER_ID=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$ALF_BASE/nodes/-root-/children" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${FOLDER_NAME}\",\"nodeType\":\"cm:folder\"}" 2>/dev/null | jq -r '.entry.id // empty')
if [ -n "$FOLDER_ID" ]; then
  pass "C1: fixture folder /${FOLDER_NAME} created (${FOLDER_ID})"
else
  fail "C1: could not create the fixture folder"
  exit 1
fi

upload() {
  local name="$1" mime="${2:-text/plain}"
  curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$ALF_BASE/nodes/${FOLDER_ID}/children" \
    -F "filedata=@${TMPDIR_DATA}/${name};type=${mime}" -F "name=${name}" 2>/dev/null \
    | jq -r '.entry.id // empty'
}
SURVEY_ID=$(upload harbour-survey.txt)
KILN_ID=$(upload kiln-maintenance.md "text/markdown")
TENDER_ID=$(upload restricted-tender.txt)
BERTH_ID=$(upload group-granted-berth.txt)
if [ -n "$SURVEY_ID" ] && [ -n "$KILN_ID" ] && [ -n "$TENDER_ID" ] && [ -n "$BERTH_ID" ]; then
  pass "C2: ${FIXTURE_COUNT} documents uploaded"
else
  fail "C2: upload failed (survey=${SURVEY_ID} kiln=${KILN_ID} tender=${TENDER_ID} berth=${BERTH_ID})"
  exit 1
fi

# restricted-tender.txt is readable by admin alone: inheritance off, no other authority. It is the ACL
# assertion's subject, and the reason this suite creates a second user at all.
create_user() {
  local id="$1"
  local code
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST "$ALF_BASE/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${id}\",\"firstName\":\"Cmis\",\"lastName\":\"Reader\",\"email\":\"${id}@test.local\",\"password\":\"password\"}")
  case "$code" in 201|409) return 0 ;; *) return 1 ;; esac
}
CMIS_READER="cmis-reader"
create_user "$CMIS_READER" || warn "could not create ${CMIS_READER}; the ACL assertion will be skipped"

restrict_to_admin() {
  local node_id="$1"
  curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT "$ALF_BASE/nodes/${node_id}" \
    -H 'Content-Type: application/json' \
    -d '{"permissions":{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"admin","name":"Coordinator","accessStatus":"ALLOWED"}]}}'
}
if [ "$(restrict_to_admin "$TENDER_ID")" = "200" ]; then
  pass "C3: restricted-tender.txt restricted to admin (inheritance off)"
else
  fail "C3: could not restrict restricted-tender.txt"
fi

# --- The group-grant fixture, which asserts an accepted limitation as behaviour ---
# CMIS has no memberOf in the specification, so nothing at query time can say which CMIS groups a caller is
# in. A document granted only to a group is therefore invisible to its members: fail-closed, so nothing leaks,
# but incomplete. That is accepted rather than fixed, and this fixture is what makes it verifiable instead of
# assumed.
#
# Granted to the group AND to admin by name. The by-name grant is not redundant: the Alfresco administrator
# bypass is keyed on the alfresco source type and never covers a cmis source, so without it admin could not
# retrieve this document either and the pair of assertions below would not distinguish "group grants do not
# resolve" from "this document was never ingested".
GROUP_SHORT="cmis-berth-${RUN_TAG}"
GROUP_ID="GROUP_${GROUP_SHORT}"
group_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST "$ALF_BASE/groups" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"${GROUP_SHORT}\",\"displayName\":\"CMIS berth readers ${RUN_TAG}\"}")
member_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  -X POST "$ALF_BASE/groups/${GROUP_ID}/members" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"${CMIS_READER}\",\"memberType\":\"PERSON\"}")
grant_code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT "$ALF_BASE/nodes/${BERTH_ID}" \
  -H 'Content-Type: application/json' \
  -d "{\"permissions\":{\"isInheritanceEnabled\":false,\"locallySet\":[
        {\"authorityId\":\"${GROUP_ID}\",\"name\":\"Consumer\",\"accessStatus\":\"ALLOWED\"},
        {\"authorityId\":\"admin\",\"name\":\"Coordinator\",\"accessStatus\":\"ALLOWED\"}]}}")
if [ "$group_code" = "201" ] || [ "$group_code" = "409" ]; then
  case "$member_code" in 201|409) member_ok=true ;; *) member_ok=false ;; esac
else
  member_ok=false
fi
if [ "$member_ok" = "true" ] && [ "$grant_code" = "200" ]; then
  pass "C23: group-granted-berth.txt granted to ${GROUP_ID} (which ${CMIS_READER} is in) and to admin by name"
else
  fail "C23: could not set up the group grant (group=${group_code} member=${member_code} acl=${grant_code})"
fi

# Diagnose from the source system before trusting either assertion below. One CMIS call shows the ACEs as the
# connector will read them, so a failure downstream is attributable to the mapping or the query rather than to
# a fixture that was never what it was meant to be. This has paid off here before: an ACL assertion that
# looked like a mapping bug turned out to be a test asserting the wrong thing.
# /root and not /<repositoryId>/root: the browser binding's rootFolderUrl carries no repository-id segment,
# and every other shape answers {"exception":"notSupported"} with a 200, so a wrong URL here reads as an empty
# ACL rather than as an error.
acl_json=$(curl -s $CURL_OPTS -u "$ALF_AUTH" \
  "${CMIS_BROWSER_HOST}/root?objectId=${BERTH_ID}&cmisselector=acl&onlyBasicPermissions=true" \
  2>/dev/null || echo '{}')
acl_principals=$(echo "$acl_json" | jq -r '[.aces[]?.principal.principalId] | sort | unique | join(", ")' \
  2>/dev/null || echo "")
info "Source ACEs on group-granted-berth.txt: ${acl_principals:-<none read>}"
if echo "$acl_principals" | grep -q "$GROUP_ID"; then
  if echo "$acl_principals" | grep -qw "$CMIS_READER"; then
    # Would make the absence assertion unfalsifiable: the reader would match by name, not through the group.
    fail "C24: the source ACL grants ${CMIS_READER} by name, so C25 could not distinguish a group grant"
  else
    pass "C24: the source ACL names ${GROUP_ID} and does not grant ${CMIS_READER} by name"
  fi
else
  fail "C24: ${GROUP_ID} is not in the source ACL (read: ${acl_principals:-<none>}), so C25 would prove nothing"
fi

# ── The native adapter first, so there is a set to compare against ─────────────
# One REST call for the expected document set, instead of a second full ingest through the native adapter
# to learn the same number. "The same document set as the native adapter for the same scope" is, for a
# folder, "every document the folder holds", and the repository can simply be asked.
FOLDER_DOCS=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
  "$ALF_BASE/nodes/${FOLDER_ID}/children?fields=id,isFile&maxItems=100" 2>/dev/null \
  | jq '[.list.entries[]? | select(.entry.isFile)] | length')
if [ "${FOLDER_DOCS:-0}" = "$FIXTURE_COUNT" ]; then
  pass "C4: /${FOLDER_NAME} holds ${FOLDER_DOCS} documents, which is what the CMIS pass has to find"
else
  fail "C4: the folder holds ${FOLDER_DOCS:-0} documents, expected ${FIXTURE_COUNT}"
  exit 1
fi

# ── The jar, built only when there is not one ──────────────────────────────────
section "Connector jar"
if [ "$BUILD_JAR" = "true" ] || [ ! -f "$BUILT_JAR" ]; then
  info "Building ${JAR_NAME} (no jar present, or BUILD_JAR=true)"
  # In a container, so this needs no host Maven or JDK 25. content-lake-spi is installed first: the
  # connector depends on it as `provided` and is deliberately not part of the reactor.
  docker run --rm -v "$(cd "$APP_SOURCE" && pwd):/src" -v "connector-test-m2:/root/.m2" \
    -w /src maven:3.9.11-eclipse-temurin-25-alpine \
    sh -c "mvn -q -B -pl common/content-lake-spi -am install -DskipTests \
        && mvn -q -B -f plugins/cmis-connector/pom.xml package" \
    || { fail "C5: the CMIS connector failed to build"; exit 1; }
fi

if [ -f "$BUILT_JAR" ]; then
  pass "C5: ${JAR_NAME} is present ($(du -h "$BUILT_JAR" | cut -f1))"
else
  fail "C5: ${JAR_NAME} was not produced"
  exit 1
fi

# Asserted on the jar the build produced, not on a copy of it: ConnectorPluginLoader resolves nothing for
# a plugin, so a jar without its OpenCMIS dependency loads and then fails on the first call. Shading is
# also the part of this connector's build that can regress without anything else noticing.
if [ "$(unzip -l "$BUILT_JAR" | grep -c 'org/apache/chemistry/opencmis')" -gt 100 ]; then
  pass "C6: the jar carries its OpenCMIS dependency"
else
  fail "C6: the jar has no OpenCMIS classes in it"
fi
if [ "$(unzip -l "$BUILT_JAR" | grep -c 'org/hyland/contentlake/spi/')" -eq 0 ]; then
  pass "C7: the jar does not bundle the SPI, so its types are the host's"
else
  fail "C7: the jar bundles content-lake-spi; the plugin's SPI types would not be the host's"
fi

cp "$BUILT_JAR" "connectors/${JAR_NAME}"
# The container runs as a non-root user and mounts this directory read-only.
chmod 644 "connectors/${JAR_NAME}"


section "Start plugin-batch-ingester with the CMIS connector"
# The deployment's own configuration, sourced HERE and this run's settings re-applied AFTERWARDS:
# `set -a; . ./.env` assigns unconditionally, so anything exported before this point is overwritten.
set -a
# shellcheck disable=SC1091
. ./.env
# shellcheck disable=SC1091
[ -f ./.env.local ] && . ./.env.local
set +a

export CONNECTOR_SOURCE_TYPE="$SOURCE_TYPE"
export CONNECTOR_SYNC_USERNAME="$SYNC_USER"
export CONNECTOR_SYNC_PASSWORD="$SYNC_PASS"
export CMIS_URL="$CMIS_ENDPOINT"
export CMIS_USERNAME="${ALF_AUTH%%:*}"
export CMIS_PASSWORD="${ALF_AUTH##*:}"
export CMIS_ROOT_PATH="/${FOLDER_NAME}"
export CMIS_SOURCE_ID="alfresco-cmis"
export CONTENT_LAKE_GIT_CONTEXT="${LOCAL_APP_CONTEXT}"
info "Ingesting ${CMIS_ROOT_PATH} over CMIS from ${CMIS_URL}"

# Build and start as two steps, never `up --build`: `--build` applies to dependencies too, and would
# rebuild every dependency image, including the slow ACS image.
if ! dc build plugin-batch-ingester; then
  fail "C8: plugin-batch-ingester image did not build"
  exit 1
fi
if ! dc up -d --no-deps plugin-batch-ingester; then
  fail "C8: plugin-batch-ingester did not start"
  exit 1
fi

elapsed=0; health=""
while [ $elapsed -lt 180 ]; do
  health=$(curl -s -o /dev/null -w '%{http_code}' "${INGESTER}/actuator/health" 2>/dev/null )
code="${code:-000}"
  [ "$health" = "200" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$health" = "200" ]; then
  pass "C8: the ingester came up with the CMIS connector loaded (${elapsed}s)"
else
  fail "C8: the ingester never became healthy (last HTTP ${health})"
  dc logs --tail 80 plugin-batch-ingester
  exit 1
fi

listing=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors" 2>/dev/null || echo '{}')
if [ "$(echo "$listing" | jq -r --arg t "$SOURCE_TYPE" '[.connectors[]? | select(.sourceType == $t)] | length')" = "1" ] \
   && [ "$(echo "$listing" | jq -r '.problems | length')" = "0" ]; then
  pass "C9: cmis is listed at /api/connectors with no load problems"
else
  fail "C9: listing is $(echo "$listing" | jq -c .)"
fi

schema=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/connectors/schema" 2>/dev/null || echo '[]')
# .required/.secret] | first // false: boolean fields expected to be true or missing; false fallthrough == false is correct.
url_required=$(echo "$schema" | jq -r '[.[]?.fields[]? | select(.name == "cmis.url") | .required] | first // false')
password_secret=$(echo "$schema" | jq -r '[.[]?.fields[]? | select(.name == "cmis.password") | .secret] | first // false')
if [ "$url_required" = "true" ] && [ "$password_secret" = "true" ]; then
  pass "C10: the schema publishes cmis.url as required and cmis.password as secret"
else
  fail "C10: cmis.url required=${url_required}, cmis.password secret=${password_secret}"
fi

# ── Ingest over CMIS ───────────────────────────────────────────────────────────
section "CMIS sync"
job=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job_id=$(echo "$job" | jq -r '.jobId // empty')
if [ -n "$job_id" ] && [ "$(echo "$job" | jq -r '.sourceType')" = "$SOURCE_TYPE" ]; then
  pass "C11: sync started for source type cmis (job ${job_id})"
else
  fail "C11: sync did not start. Response: $(echo "$job" | jq -c .)"
  dc logs --tail 80 plugin-batch-ingester
  exit 1
fi

elapsed=0; status=""
while [ $elapsed -lt "$POLL_DEADLINE_S" ]; do
  status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
  case "$status" in COMPLETED|FAILED) break ;; esac
  sleep 5; elapsed=$((elapsed+5))
done
final=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null || echo '{}')
discovered=$(echo "$final" | jq -r '.discoveredCount // 0')
synced=$(echo "$final" | jq -r '.syncedCount // 0')
failed=$(echo "$final" | jq -r '.failedCount // 0')
if [ "$status" = "COMPLETED" ] && [ "$failed" = "0" ]; then
  pass "C12: the CMIS job completed with no failures in ${elapsed}s (discovered=${discovered} synced=${synced})"
else
  fail "C12: job status=${status} failed=${failed}: $(echo "$final" | jq -c .)"
  dc logs --tail 80 plugin-batch-ingester
fi

# #125's first acceptance criterion, without paying for a second ingest: the CMIS traversal found exactly
# the documents the folder holds, no more (multi-filing would double-count) and no fewer.
if [ "$discovered" = "$FOLDER_DOCS" ] && [ "$synced" = "$FOLDER_DOCS" ]; then
  pass "C13: CMIS discovered and synced the folder's ${FOLDER_DOCS} documents, no more and no fewer"
else
  fail "C13: CMIS discovered ${discovered} and synced ${synced}, the folder holds ${FOLDER_DOCS}"
fi

# ── Retrievable, without pinning a permission source ───────────────────────────
section "Recreate rag-service with CMIS as its only authentication path"
# Needed anyway, because RAG_SECURITY_CMIS_* has to reach the container. Blanking the other two costs nothing
# extra and is what makes C21 below mean something: with an Alfresco and a Nuxeo URL configured, a caller who
# happens to exist in Alfresco authenticates there and the assertion would prove Alfresco authentication, not
# CMIS. Both of those authenticators decline without a call on a blank base URL.
#
# So this suite must NOT run concurrently with test-alfresco.sh or the Nuxeo suite: they authenticate real
# users against those two sources, and for the duration of this block nobody can.
#
# If a blank URL ever breaks startup, use an unresolvable .invalid host rather than a routable dead one, so
# DNS fails fast instead of the request hanging to its timeout on every login.
export ALFRESCO_URL=""
export NUXEO_URL=""
export RAG_SECURITY_CMIS_ENABLED=true
export RAG_SECURITY_CMIS_URL="$CMIS_ENDPOINT"
export RAG_SECURITY_CMIS_REPOSITORY_ID="-default-"
RAG_RECONFIGURED=true
# Built, not just recreated: the authenticator is new code, so a stack brought up before it existed runs an
# image with no such bean, and every assertion below would fail as "not retrievable" with no hint why.
if ! dc build rag-service; then
  fail "C27: the rag-service image did not build"
  exit 1
fi
if ! dc up -d --no-deps --force-recreate rag-service >/dev/null 2>&1; then
  fail "C27: rag-service did not restart with the CMIS authenticator"
  exit 1
fi
# 300s, matching run-tests.sh and test-sharepoint.sh: a force-recreated rag-service boots a JVM and waits on
# its dependencies, and 180s was measured elsewhere in this repository as not enough.
elapsed=0; rag=""
while [ $elapsed -lt 300 ]; do
  rag=$(curl -s $CURL_OPTS -u "$RAG_AUTH" "${RAG_URL}/health" 2>/dev/null | jq -r '.status // "?"')
  [ "$rag" = "UP" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$rag" = "UP" ]; then
  pass "C27: rag-service is UP with CMIS as its only caller authentication (${elapsed}s)"
else
  fail "C27: rag-service never became UP (last status ${rag})"
  dc logs --tail 80 rag-service
  exit 1
fi

section "Retrieval"
# No rag.permission.source-ids pin here, unlike test-connector.sh: since #133 the permission filter
# discovers every source in the index and builds a clause for each, so a source rag-service was never
# compiled against is retrievable as ingested. A pin would mask exactly that.
# Matched on a phrase unique to the document AND on the run tag, not on the tag alone: every fixture in a
# run carries the tag, so a tag-only match makes an absence assertion unfalsifiable -- any readable
# fixture satisfies it, and the one document the ACL should be hiding is never what was checked.
find_document() {
  local query="$1" phrase="$2" label="$3" tid="$4" auth="${5:-$RAG_AUTH}" expect="${6:-found}"
  local waited=0 resp hits deadline
  # An absence is concluded in ONE probe rather than polled to a deadline. Its precondition is that a
  # presence assertion for the same document has already passed under a different caller (C16 for the
  # restricted fixture, C25 for the group-granted one), which is what proves retrieval works at all; without
  # that, a single probe would be satisfied by a broken pipeline. Waiting to conclude an absence spent a
  # minute per assertion to report nothing that the first probe had not already reported.
  deadline=$([ "$expect" = "found" ] && echo "$POLL_DEADLINE_S" || echo 0)
  while :; do
    resp=$(curl $CURL_OPTS -sf -u "$auth" -X POST "${RAG_URL}/search/semantic" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"${query}\",\"topK\":30,\"minScore\":0.2}" 2>/dev/null || echo '{}')
    hits=$(echo "$resp" | jq --arg src "${SOURCE_TYPE}:" --arg tag "$RUN_TAG" --arg phrase "$phrase" \
      '[.results[]? | select((.sourceDocument.sourceId // "") | startswith($src))
                    | select((.chunkText // "") | test($tag; "i"))
                    | select((.chunkText // "") | test($phrase; "i"))] | length' 2>/dev/null || echo 0)
    if [ "${hits:-0}" -gt 0 ]; then
      if [ "$expect" = "found" ]; then
        pass "${tid}: ${label} (after ${waited}s)"
      else
        fail "${tid}: ${label} - it WAS returned, which is an ACL leak"
      fi
      return 0
    fi
    waited=$((waited+10))
    [ $waited -ge "$deadline" ] && break
    sleep 10
  done
  if [ "$expect" = "found" ]; then
    fail "${tid}: ${label} - not retrievable after ${waited}s"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, src:.sourceDocument.sourceId, score:.score}]')"
    return 1
  fi
  pass "${tid}: ${label}"
}

find_document "How much silt was removed from the outer channel at Skagen?" "Skagen" \
  "harbour-survey.txt is retrievable from the cmis source" "C14"
find_document "What was kiln four's refractory lining replaced with?" "magnesia-chrome" \
  "kiln-maintenance.md (markdown) is retrievable from the cmis source" "C15"

# ── ACL mapping, which is what CMIS makes optional ─────────────────────────────
section "ACL mapping"
# Alfresco reports capabilityACL=manage, so the connector reads real ACEs. Two documents in one folder
# with different ACLs is the test: one inherits GROUP_EVERYONE from the folder, the other is restricted
# to admin with inheritance off. A connector that ignored ACLs would return both to any caller.
find_document "What was the sealed bid for the Frederikshavn quay extension priced at?" "Frederikshavn" \
  "restricted-tender.txt is retrievable by admin" "C16"
# C21 to C27 are all numbered after the suite's previous last id (C20) rather than renumbering the file, so
# they read out of order wherever they appear. C21 and C22 run here, before C17 and C18, because they are the
# precondition for them: an absence assertion proves nothing until the caller is known to authenticate.
#
# What they replace: a guard that could never fail. `curl` without --fail exits 0 for any HTTP response, and
# /api/rag/health is permitAll anyway, so the warn-and-skip branch was unreachable and the guard proved
# nothing about the reader. Worse, C17 is an ABSENCE assertion, so if the reader could not authenticate at all
# it would have passed vacuously: every search 401s, zero hits, "absent" satisfied. An authenticated endpoint
# and a real status code are what make C17 mean something.
section "The reader can authenticate, which is C17's precondition"
search_status() {
  local auth="$1" code
  # No `|| echo` here: curl writes %{http_code} itself even when it cannot connect, writing 000, and then
  # exits non-zero, so the usual idiom concatenates the two and reports HTTP 000000. The default belongs on
  # an empty result, not on a failed exit.
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$auth" -X POST "${RAG_URL}/search/semantic" \
    -H 'Content-Type: application/json' -d '{"query":"authentication probe","topK":1}' 2>/dev/null)
  echo "${code:-000}"
}
reader_code=$(search_status "${CMIS_READER}:password")
if [ "$reader_code" = "200" ]; then
  pass "C21: ${CMIS_READER} authenticates on an authenticated endpoint (HTTP 200)"
else
  fail "C21: ${CMIS_READER} could not authenticate for a search (HTTP ${reader_code}); C17 below would pass vacuously"
fi
# So C21 is not an anonymous pass: the same call with a wrong password must be refused.
wrong_code=$(search_status "${CMIS_READER}:definitely-not-the-password")
if [ "$wrong_code" = "401" ]; then
  pass "C22: a wrong password for ${CMIS_READER} is refused (HTTP 401)"
else
  fail "C22: a wrong password returned HTTP ${wrong_code}, so C21 does not prove authentication"
fi

find_document "What was the sealed bid for the Frederikshavn quay extension priced at?" "Frederikshavn" \
  "restricted-tender.txt is NOT retrievable by ${CMIS_READER}" "C17" "${CMIS_READER}:password" "absent"
find_document "How much silt was removed from the outer channel at Skagen?" "Skagen" \
  "harbour-survey.txt IS retrievable by ${CMIS_READER} (inherited GROUP_EVERYONE)" "C18" \
  "${CMIS_READER}:password"

# The accepted group limitation, asserted in both directions. C25 first, because it is the falsifiability
# check: it proves the document was ingested and its ACL mapped, without which C26 would pass for the wrong
# reason. admin retrieves it through the by-name grant, not a bypass, which does not apply to a cmis source.
find_document "Which mooring was reassigned to the inshore fleet after the storm damage survey?" \
  "Hirtshals pontoon" \
  "group-granted-berth.txt IS retrievable by admin (granted by name)" "C25"
find_document "Which mooring was reassigned to the inshore fleet after the storm damage survey?" \
  "Hirtshals pontoon" \
  "group-granted-berth.txt is NOT retrievable by ${CMIS_READER} despite their group grant" "C26" \
  "${CMIS_READER}:password" "absent"

# Stated rather than asserted, so the gap is owned: the fail-closed path cannot be exercised here.
info "Not covered by this suite: a repository reporting capabilityACL=NONE. Alfresco reports 'manage',"
info "so the fail-closed refusal and the sync-account/public fallbacks are unit-tested only"
info "(CmisAclMapperTest), and the connector logs which one is in force at startup."
# The second gap is asserted rather than merely stated, by C25 and C26, but it belongs on this list too
# because it is a limitation an operator has to know about rather than a case the suite skips.
info "Also a known limitation, not a defect: CMIS group grants do not resolve at query time, because CMIS"
info "has no memberOf operation. A document granted only to a group is invisible to its members"
info "(fail-closed, so nothing leaks, but results are incomplete). C25 and C26 assert exactly that."

# ── Idempotency ────────────────────────────────────────────────────────────────
section "Re-sync"
metric() {
  curl -sf -u "$SYNC_AUTH" "${INGESTER}/actuator/metrics/$1" 2>/dev/null \
    | jq -r '.measurements[0].value // 0' 2>/dev/null || echo 0
}
# Baselined rather than compared against a fixture count: these counters are process-wide and this
# service is shared with test-connector.sh, so a run that follows it starts from a non-zero count.
reprocesses_before=$(metric contentlake.ingest.content.reprocesses)
shortcircuits_before=$(metric contentlake.ingest.content.shortcircuits)
# #120: unchanged content is not re-chunked or re-embedded. This also proves the connector returns a
# stable modifiedAt, without which every pass would re-extract and re-embed the whole corpus.
job2=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null || echo '{}')
job2_id=$(echo "$job2" | jq -r '.jobId // empty')
elapsed=0; status=""
while [ -n "$job2_id" ] && [ $elapsed -lt "$POLL_DEADLINE_S" ]; do
  status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job2_id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
  case "$status" in COMPLETED|FAILED) break ;; esac
  sleep 5; elapsed=$((elapsed+5))
done
final2=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job2_id}" 2>/dev/null || echo '{}')
if [ "$status" = "COMPLETED" ] && [ "$(echo "$final2" | jq -r '.failedCount // 0')" = "0" ]; then
  pass "C19: the second CMIS sync completed with no failures"
else
  fail "C19: second sync status=${status}: $(echo "$final2" | jq -c .)"
fi

# What is asserted is that the second pass did not re-embed. Two mechanisms reach that and which one
# fires is a property of the source, not of this host: since #147 a connector's modifiedAt is stored, so
# a source whose timestamp round-trips exactly is caught by the metadata staleness check and never
# reaches extraction, while one whose timestamp is absent or coarser reaches extraction and is caught by
# the content fingerprint. CMIS reports millisecond precision and takes the first path. Asserting the
# short circuit specifically failed this suite for taking the cheaper route.
short_circuits=$(metric contentlake.ingest.content.shortcircuits)
reprocesses=$(metric contentlake.ingest.content.reprocesses)
reprocessed=$(( ${reprocesses%.*} - ${reprocesses_before%.*} ))
short_circuited=$(( ${short_circuits%.*} - ${shortcircuits_before%.*} ))
if [ "$reprocessed" -gt 0 ]; then
  fail "C20: the second pass re-embedded ${reprocessed} document(s) (shortcircuits +${short_circuited}, reprocesses +${reprocessed})"
elif [ "$short_circuited" -ge "$FIXTURE_COUNT" ]; then
  pass "C20: the second pass reused stored content for all ${FIXTURE_COUNT} documents (shortcircuits +${short_circuited})"
else
  pass "C20: the second pass re-embedded nothing, skipped on metadata before extraction (shortcircuits +${short_circuited}, reprocesses +${reprocessed})"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
printf "\n${B}CMIS suite: ${G}%d passed${N}, ${R}%d failed${N}\n" "$PASS" "$FAIL"
printf "Log: %s\n" "$LOG"
[ "$FAIL" -eq 0 ]
