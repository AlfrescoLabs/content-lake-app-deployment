#!/usr/bin/env bash
# test-sharepoint-real.sh - the SharePoint connector against a real SharePoint Online site, app-only.
#
# test-sharepoint.sh proves the connector against the mock Graph service. This proves what the mock cannot:
# a client-credentials token from Entra ID, whether Sites.Selected authorises the change feed and the
# permission reads, real ACL payloads, and the query path against a real directory.
#
# The site must hold the fixture tree from fixtures/create-sharepoint-demo-files.sh, shared as its README
# says. The suite checks that first, against the site's own permissions, so a fixture that was not shared
# as required is reported as a setup problem rather than as a connector defect.
#
# Opt-in, like test-sharepoint.sh, and not a phase of run-tests.sh: it needs a tenant and a secret.
#
# What it does NOT do:
#   - It does not create or change anything in the tenant. The app is granted Read on the site only.
#   - It does not rebuild the connector jar when one is already built. Pass BUILD_JAR=true to force it.
#   - It does not sign anybody in to Microsoft. The checks that need a caller's own Entra token run only
#     when ENTRA_BEARER_TOKEN is set, and are reported as skipped otherwise.
#
# Prerequisites:
#   - the alfresco (or full/demo) base stack up and healthy, from wiped volumes (make clean)
#   - the AI backend on :12434
#   - Docker, curl, jq, and the Azure CLI signed in to the tenant (for the Graph-token rejection check)
#   - the connection file (written by dev/scripts/sharepoint-secret.py export), mode 600
#
# Usage:
#   CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin ./test/test-sharepoint-real.sh
#
# Environment variables:
#   CONNECTION_FILE     Real-tenant settings, secret included (default ~/Downloads/credentials/sharepoint-connection.env)
#   GROUP_ID            Object id of the Entra or Microsoft 365 group GroupScoped/ is shared with (required)
#   ENTRA_BEARER_TOKEN  A token for api://<ui-client-id>/access_as_user, of a member of GROUP_ID (optional)
#   RAG_AUTH, HOST, USE_HTTPS, APP_SOURCE, BUILD_JAR, POLL_DEADLINE_S, KEEP_RUNNING  as in test-sharepoint.sh
#   CRAWL_DEADLINE_S    Seconds to wait for the crawl to finish (default 400)
#   MEMBERSHIP_LOOKUP   rag-service's rag.security.entra.membership-lookup for this run (default user). Under
#                       user, a caller known by address has groups, so R18b runs; under group only an
#                       object-id caller has groups, and R18b is skipped
#   GROUP_MEMBER        Address of a member of GROUP_ID, for R18b (default: the user named on the inherited
#                       fixture). The suite checks the membership in the directory before relying on it

set -uo pipefail

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-true}"
RAG_AUTH="${RAG_AUTH:-admin:admin}"
APP_SOURCE="${APP_SOURCE:-../content-lake-app}"
BUILD_JAR="${BUILD_JAR:-false}"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-60}"
# Measured 2026-10-26: the full crawl of 130 documents, each downloaded and embedded locally, took 264s.
CRAWL_DEADLINE_S="${CRAWL_DEADLINE_S:-400}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
CONNECTION_FILE="${CONNECTION_FILE:-$HOME/Downloads/credentials/sharepoint-connection.env}"
GROUP_ID="${GROUP_ID:?GROUP_ID is required: the object id of the group GroupScoped/ is shared with}"
ENTRA_BEARER_TOKEN="${ENTRA_BEARER_TOKEN:-}"
MEMBERSHIP_LOOKUP="${MEMBERSHIP_LOOKUP:-user}"
GROUP_MEMBER="${GROUP_MEMBER:-}"
SYNC_USER="${CONNECTOR_SYNC_USERNAME:?CONNECTOR_SYNC_USERNAME is required}"
SYNC_PASS="${CONNECTOR_SYNC_PASSWORD:?CONNECTOR_SYNC_PASSWORD is required}"
SYNC_AUTH="${SYNC_USER}:${SYNC_PASS}"

if [ "$USE_HTTPS" = "true" ]; then
  BASE="https://${HOST}"; CURL_OPTS="-k"
else
  BASE="http://${HOST}"; CURL_OPTS=""
fi
RAG_URL="${BASE}/api/rag"
ALF_BASE="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
INGESTER="http://${HOST}:9096"
GRAPH="https://graph.microsoft.com/v1.0"

CONNECTOR_DIR="${APP_SOURCE}/plugins/sharepoint-connector"
JAR_NAME="sharepoint-connector-1.0.0.jar"
BUILT_JAR="${CONNECTOR_DIR}/target/${JAR_NAME}"
SOURCE_TYPE="sharepoint"
# Seven named fixtures plus Bulk/'s 120. The generator's README is a document too, and is not counted.
EXPECTED_DOCUMENTS=127

RUN_TAG="spr-$(date +%Y%m%d-%H%M%S)-$$"
SOURCE_ID="real-${RUN_TAG}"
QUALIFIED_SOURCE="${SOURCE_TYPE}:${SOURCE_ID}"
# A caller who is neither the named user nor, as far as this suite can tell, anyone with a grant.
OUTSIDER="sp-real-outsider"

LOG="test-results-sharepoint-real-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0; SKIP=0
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
skip()    { printf "${Y}[SKIP]${N} %s\n" "$*"; SKIP=$((SKIP+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

BASE_PROFILE="${BASE_PROFILE:-alfresco}"
dc() {
  local env_args=()
  [ -f ./.env.local ] && env_args=(--env-file .env.local)
  # The connection file's values reach compose through the shell, which sourced it below.
  docker compose "${env_args[@]}" --profile "$BASE_PROFILE" --profile connector "$@"
}

cleanup() {
  if [ "$KEEP_RUNNING" = "true" ]; then
    info "KEEP_RUNNING=true: plugin-batch-ingester, the Entra settings on rag-service and the jar are left in place"
    return
  fi
  info "Removing the connector service and the jar"
  docker compose --profile "$BASE_PROFILE" --profile connector rm -sf plugin-batch-ingester >/dev/null 2>&1
  rm -f "connectors/${JAR_NAME}"
  if [ "${RAG_RECONFIGURED:-false}" = "true" ]; then
    info "Restoring rag-service without the real-tenant Entra settings"
    # Without the connection file, so the secret leaves the running container too.
    # shellcheck disable=SC2046  # one variable name per word, split on purpose
    ( unset $(grep -o '^RAG_SECURITY_ENTRA_[A-Z_]*' "$CONNECTION_FILE")
      local env_args=(); [ -f ./.env.local ] && env_args=(--env-file .env.local)
      docker compose "${env_args[@]}" --profile "$BASE_PROFILE" up -d --no-deps --force-recreate rag-service \
        >/dev/null 2>&1 )
  fi
}
trap cleanup EXIT

for tool in docker curl jq az; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 2; }
done

section "Preconditions"
if [ ! -f "$CONNECTION_FILE" ]; then
  echo "No connection file at $CONNECTION_FILE. Write it with:"
  echo "    python3 -I ../scripts/sharepoint-secret.py export $CONNECTION_FILE"
  exit 2
fi
if [ "$(stat -f '%Lp' "$CONNECTION_FILE" 2>/dev/null || stat -c '%a' "$CONNECTION_FILE")" != "600" ]; then
  echo "$CONNECTION_FILE holds a secret and must be mode 600"
  exit 2
fi
# The connection file's settings, applied after the deployment's own, as test-sharepoint.sh does.
set -a
# shellcheck disable=SC1091
. ./.env
# shellcheck disable=SC1091
[ -f ./.env.local ] && . ./.env.local
# shellcheck disable=SC1090
. "$CONNECTION_FILE"
set +a
export RAG_SECURITY_ENTRA_MEMBERSHIP_LOOKUP="$MEMBERSHIP_LOOKUP"
for key in SHAREPOINT_TENANT_ID SHAREPOINT_CLIENT_ID SHAREPOINT_CLIENT_SECRET SHAREPOINT_DRIVE_IDS \
           RAG_SECURITY_ENTRA_CALLER_AUTH_CLIENT_ID; do
  [ -n "${!key:-}" ] || { echo "$key is not set in $CONNECTION_FILE"; exit 2; }
done
DRIVE_ID="${SHAREPOINT_DRIVE_IDS%%,*}"

require_serving() {
  local what="$1" url="$2" auth="$3" code
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$auth" "$url" 2>/dev/null)
  code="${code:-000}"
  [ "$code" = "200" ] && { info "${what} is serving"; return 0; }
  echo "The base stack is not serving: ${what} answered HTTP ${code} at ${url}"
  echo "Bring one up first:    make clean && make up-${BASE_PROFILE}"
  exit 2
}
require_serving "rag-service" "${RAG_URL}/health" "$RAG_AUTH"
require_serving "Alfresco" "${ALF_BASE}/nodes/-root-" "$ALF_AUTH"
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:12434/ 2>/dev/null); code="${code:-000}"
[ "$code" != "000" ] || { echo "Nothing is listening on :12434, so embedding will fail"; exit 2; }
[ -f "$BUILT_JAR" ] || [ "$BUILD_JAR" = "true" ] || { echo "No jar at $BUILT_JAR (build it, or BUILD_JAR=true)"; exit 2; }

# --- The tenant, asked directly -------------------------------------------------------------------
section "The tenant, asked directly"
APP_TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/${SHAREPOINT_TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${SHAREPOINT_CLIENT_ID}" \
  --data-urlencode "client_secret=${SHAREPOINT_CLIENT_SECRET}" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')
if [ -n "$APP_TOKEN" ]; then
  pass "R1: Entra ID issued an app-only token for the connector's registration"
else
  fail "R1: no app-only token; check the secret in $CONNECTION_FILE and its expiry"
  exit 1
fi
graph() { curl -s -H "Authorization: Bearer ${APP_TOKEN}" "${GRAPH}$1"; }
graph_code() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${APP_TOKEN}" "${GRAPH}$1"; }

# The question #170 asks: Microsoft's reference lists Sites.Selected for neither call.
delta_code=$(graph_code "/drives/${DRIVE_ID}/root/delta?\$top=1")
if [ "$delta_code" = "200" ]; then
  pass "R2: Sites.Selected authorises driveItem delta (HTTP 200)"
else
  fail "R2: driveItem delta answered HTTP ${delta_code} under Sites.Selected; escalate, do not switch scopes quietly"
fi

item_id() { graph "/drives/${DRIVE_ID}/root:/$1" | jq -r '.id // empty'; }
NAMED_ID=$(item_id "UserScoped/named-grant.txt")
GROUP_ITEM_ID=$(item_id "GroupScoped/group-grant.txt")
if [ -z "$NAMED_ID" ] || [ -z "$GROUP_ITEM_ID" ]; then
  echo "The fixture tree is not on the site. Generate it with fixtures/create-sharepoint-demo-files.sh,"
  echo "upload it to the library root, and share it as its README says."
  exit 2
fi
named_perms=$(graph "/drives/${DRIVE_ID}/items/${NAMED_ID}/permissions")
if echo "$named_perms" | jq -e '.value' >/dev/null 2>&1; then
  pass "R3: Sites.Selected authorises List permissions on an item"
else
  fail "R3: List permissions refused: $(echo "$named_perms" | jq -c '.error // .' | cut -c1-200)"
  exit 1
fi

# The source's own ACL, read before anything is ingested, so a wrong fixture is a setup error and not a
# connector defect. Read principals ignore owners: an owner grant is the site's, not the fixture's.
NAMED_USER=$(echo "$named_perms" | jq -r '[.value[] | select((.roles | index("owner")) | not)
  | .grantedToV2.user.email // .grantedToV2.user.userPrincipalName // empty] | unique | if length == 1 then .[0] else empty end')
named_wide=$(echo "$named_perms" | jq -r '[.value[] | select(.link.scope == "organization" or .link.scope == "anonymous"
  or ((.grantedToV2.siteGroup // .grantedToV2.group) != null))] | length')
if [ -n "$NAMED_USER" ] && [ "$named_wide" = "0" ]; then
  pass "R4: named-grant.txt is shared with exactly one named user and nothing wider"
else
  echo "UserScoped/ must be shared with one named colleague and nothing else (Stop sharing first)."
  echo "Non-owner grants found: $(echo "$named_perms" | jq -c '[.value[] | {roles, link: .link.scope, user: .grantedToV2.user.email, group: .grantedToV2.group.displayName, siteGroup: .grantedToV2.siteGroup.displayName}]')"
  exit 2
fi
group_perms=$(graph "/drives/${DRIVE_ID}/items/${GROUP_ITEM_ID}/permissions")
if [ "$(echo "$group_perms" | jq -r --arg g "$GROUP_ID" '[.value[] | select(.grantedToV2.group.id == $g)] | length')" -gt 0 ] \
   && [ "$(echo "$group_perms" | jq -r '[.value[] | select(.grantedToV2.siteGroup != null)] | length')" = "0" ]; then
  pass "R5: group-grant.txt is granted to group ${GROUP_ID}, and to no site-local group"
else
  echo "GroupScoped/ must be shared with group ${GROUP_ID} and never with the site's Owners, Members or Visitors."
  exit 2
fi
# An inherited item carries the site's Owners, Members and Visitors groups, and those are SharePoint site
# groups that no query-time resolver expands. The only principal a caller can match on it is a user granted
# by name, which is the site owner Graph lists alongside the groups. R12 to R15 query as that user.
inherited_perms=$(graph "/drives/${DRIVE_ID}/items/$(item_id "Public/quarterly-review.txt")/permissions")
INHERITED_USER=$(echo "$inherited_perms" | jq -r '[.value[] | .grantedToV2.user.email // .grantedToV2.user.userPrincipalName // empty]
  | unique | .[0] // empty')
if [ -z "$INHERITED_USER" ]; then
  echo "Public/quarterly-review.txt has no user granted by name, so no caller can read inherited documents."
  exit 2
fi
GROUP_MEMBER="${GROUP_MEMBER:-$INHERITED_USER}"
is_member=$(curl -s -H "Authorization: Bearer ${APP_TOKEN}" -H 'Content-Type: application/json' \
  -X POST "${GRAPH}/users/${GROUP_MEMBER}/checkMemberGroups" -d "{\"groupIds\":[\"${GROUP_ID}\"]}" \
  | jq -r --arg g "$GROUP_ID" '(.value // []) | index($g) != null')
if [ "$is_member" != "true" ]; then
  echo "${GROUP_MEMBER} is not a member of group ${GROUP_ID}, or the app cannot read users. Set GROUP_MEMBER."
  exit 2
fi

# --- Callers --------------------------------------------------------------------------------------
section "Callers"
# An Alfresco caller named exactly as Graph names the user, case included: the mapper stores the address as
# Graph sends it, and the permission filter compares it verbatim.
for user in $(printf "%s\n" "$NAMED_USER" "$INHERITED_USER" "$GROUP_MEMBER" "$OUTSIDER" | sort -u); do
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST "${ALF_BASE}/people" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg id "$user" '{id:$id, firstName:$id, email:(if ($id|contains("@")) then $id else ($id + "@example.com") end), password:($id + "-pw")}')")
  case "$code" in
    201|409) pass "R6: the Alfresco caller ${user} exists" ;;
    *)       fail "R6: could not create ${user} (HTTP ${code})" ;;
  esac
done

# --- Services -------------------------------------------------------------------------------------
section "Start the connector and reconfigure rag-service"
cp "$BUILT_JAR" "connectors/${JAR_NAME}" && chmod 644 "connectors/${JAR_NAME}"
export CONNECTOR_SOURCE_TYPE="$SOURCE_TYPE" CONNECTOR_SYNC_USERNAME="$SYNC_USER" CONNECTOR_SYNC_PASSWORD="$SYNC_PASS"
export SHAREPOINT_SOURCE_ID="$SOURCE_ID" CONTENT_LAKE_GIT_CONTEXT="${CONTENT_LAKE_GIT_CONTEXT:-$APP_SOURCE}"
RAG_RECONFIGURED=true
for service in rag-service plugin-batch-ingester; do
  dc build "$service" >/dev/null || { fail "R7: ${service} did not build"; exit 1; }
  dc up -d --no-deps --force-recreate "$service" >/dev/null 2>&1 || { fail "R7: ${service} did not start"; exit 1; }
done
# 300s, as in test-sharepoint.sh: a recreated rag-service boots a JVM and waits on its dependencies.
elapsed=0; rag=""; health=""
while [ $elapsed -lt 300 ]; do
  rag=$(curl -s $CURL_OPTS -u "$RAG_AUTH" "${RAG_URL}/health" 2>/dev/null | jq -r '.status // "?"')
  health=$(curl -s -o /dev/null -w '%{http_code}' "${INGESTER}/actuator/health" 2>/dev/null)
  [ "$rag" = "UP" ] && [ "$health" = "200" ] && break
  sleep 5; elapsed=$((elapsed+5))
done
if [ "$rag" = "UP" ] && [ "$health" = "200" ]; then
  pass "R7: rag-service and the connector are up with the real-tenant settings (${elapsed}s)"
else
  fail "R7: rag-service=${rag} ingester=${health}"
  dc logs --tail 60 rag-service plugin-batch-ingester
  exit 1
fi

# --- The crawl ------------------------------------------------------------------------------------
section "Crawl"
started=$(date +%s)
job_id=$(curl -sf -u "$SYNC_AUTH" -X POST "${INGESTER}/api/sync/configured" 2>/dev/null | jq -r '.jobId // empty')
[ -n "$job_id" ] || { fail "R8: the sync did not start"; dc logs --tail 80 plugin-batch-ingester; exit 1; }
waited=0; status=""
while [ $waited -lt "$CRAWL_DEADLINE_S" ]; do
  status=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null | jq -r '.status // "UNKNOWN"')
  case "$status" in COMPLETED|FAILED) break ;; esac
  sleep 10; waited=$((waited+10))
done
final=$(curl -sf -u "$SYNC_AUTH" "${INGESTER}/api/sync/status/${job_id}" 2>/dev/null || echo '{}')
synced=$(echo "$final" | jq -r '.syncedCount // 0'); failed=$(echo "$final" | jq -r '.failedCount // 0')
info "The crawl took $(( $(date +%s) - started ))s; record it as CRAWL_DEADLINE_S's measurement"
if [ "$status" = "COMPLETED" ] && [ "$failed" = "0" ]; then
  pass "R8: the client-credentials crawl completed with no failures (synced=${synced})"
else
  fail "R8: status=${status} failed=${failed}: $(echo "$final" | jq -c .)"
  dc logs --tail 80 plugin-batch-ingester
fi
if [ "$synced" -ge "$EXPECTED_DOCUMENTS" ]; then
  pass "R9: every fixture was ingested (${synced} >= ${EXPECTED_DOCUMENTS}), Bulk/'s second page included"
else
  fail "R9: synced ${synced}, expected at least ${EXPECTED_DOCUMENTS}"
fi
denied=$(dc logs plugin-batch-ingester 2>/dev/null | grep -c -i 'accessDenied\|HTTP 403')
if [ "$denied" = "0" ]; then
  pass "R10: Graph refused nothing during the crawl"
else
  fail "R10: ${denied} access-denied line(s) in the ingester log"
fi

# --- Retrieval and ACLs ---------------------------------------------------------------------------
section "Retrieval and ACLs"
# auth is user:password, or "bearer:<token>". Matched on this run's source id and on a phrase unique to the
# document, so a hit can only be the document meant.
find_document() {
  local query="$1" phrase="$2" label="$3" tid="$4" auth="$5" expect="${6:-found}"
  local waited=0 resp hits deadline auth_args
  if [[ "$auth" == bearer:* ]]; then auth_args=(-H "Authorization: Bearer ${auth#bearer:}"); else auth_args=(-u "$auth"); fi
  deadline=$([ "$expect" = "found" ] && echo "$POLL_DEADLINE_S" || echo 0)
  while :; do
    resp=$(curl $CURL_OPTS -sf "${auth_args[@]}" -X POST "${RAG_URL}/search/semantic" \
      -H 'Content-Type: application/json' -d "{\"query\":\"${query}\",\"topK\":30,\"minScore\":0.2}" 2>/dev/null || echo '{}')
    hits=$(echo "$resp" | jq --arg src "$QUALIFIED_SOURCE" --arg phrase "$phrase" \
      '[.results[]? | select((.sourceDocument.sourceId // "") == $src) | select((.chunkText // "") | test($phrase; "i"))] | length' 2>/dev/null || echo 0)
    if [ "${hits:-0}" -gt 0 ]; then
      if [ "$expect" = "found" ]; then pass "${tid}: ${label} (after ${waited}s)"; else fail "${tid}: ${label} - it WAS returned, an ACL leak"; fi
      return 0
    fi
    [ $waited -ge "$deadline" ] && break
    sleep 10; waited=$((waited+10))
  done
  if [ "$expect" = "found" ]; then fail "${tid}: ${label} - not retrievable after ${waited}s"; return 1; fi
  pass "${tid}: ${label}"
}

OUTSIDER_AUTH="${OUTSIDER}:${OUTSIDER}-pw"
NAMED_AUTH="${NAMED_USER}:${NAMED_USER}-pw"
INHERITED_AUTH="${INHERITED_USER}:${INHERITED_USER}-pw"
MEMBER_AUTH="${GROUP_MEMBER}:${GROUP_MEMBER}-pw"
find_document "Which document was shared with an organisation wide link?" "pangolin-ledger-orgwide" \
  "org-wide.txt is retrievable by any authenticated caller" "R11" "$OUTSIDER_AUTH"
find_document "What is the quarterly review sentinel phrase?" "pangolin-ledger-quarterly" \
  "an inherited document is retrievable" "R12" "$INHERITED_AUTH"
find_document "What does the quarterly financial report say?" "pangolin-ledger-pdf-report" \
  "the PDF is retrievable, so the extractor ran" "R13" "$INHERITED_AUTH"
find_document "What is the incident log sentinel phrase?" "pangolin-ledger-incident" \
  "the markdown file is retrievable" "R14" "$INHERITED_AUTH"
find_document "What is the deep document sentinel phrase?" "pangolin-ledger-deep" \
  "a document two levels down is retrievable" "R15" "$INHERITED_AUTH"
find_document "What is the named grant sentinel phrase?" "pangolin-ledger-named" \
  "named-grant.txt is retrievable by the user it is shared with" "R17a" "$NAMED_AUTH"
find_document "What is the named grant sentinel phrase?" "pangolin-ledger-named" \
  "named-grant.txt is NOT retrievable by another caller" "R17b" "$OUTSIDER_AUTH" "absent"
find_document "What is the named grant sentinel phrase?" "pangolin-ledger-named" \
  "named-grant.txt is NOT retrievable by the admin" "R17c" "$RAG_AUTH" "absent"
# Under membership-lookup=user, rag-service reads a caller's groups from the directory by address, so a
# member found by address proves the group grant end to end. Under group, only an object-id caller has
# groups, and R19 is the presence check instead.
if [ "$MEMBERSHIP_LOOKUP" = "user" ]; then
  find_document "What is the group grant sentinel phrase?" "pangolin-ledger-group" \
    "group-grant.txt is retrievable by a member of the group" "R18b" "$MEMBER_AUTH"
else
  skip "R18b: membership-lookup=${MEMBERSHIP_LOOKUP} gives a caller known by address no groups"
fi
find_document "What is the group grant sentinel phrase?" "pangolin-ledger-group" \
  "group-grant.txt is NOT retrievable by a caller outside the group" "R18" "$OUTSIDER_AUTH" "absent"

# --- Entra caller authentication (#168) -----------------------------------------------------------
section "Entra caller authentication"
# A Microsoft Graph token is genuinely signed by the tenant, so only the audience check can refuse it. The
# Azure CLI's own Graph token is exactly such a token, which makes this check free of any sign-in.
graph_user_token=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>/dev/null)
if [ -n "$graph_user_token" ]; then
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${graph_user_token}" \
    -X POST "${RAG_URL}/search/semantic" -H 'Content-Type: application/json' -d '{"query":"x","topK":1}')
  if [ "$code" = "401" ]; then
    pass "R20: a valid Microsoft Graph token is refused (HTTP 401): the audience is checked"
  else
    fail "R20: a Microsoft Graph token answered HTTP ${code}; it must be 401"
  fi
else
  skip "R20: the Azure CLI gave no Graph token; run az login --tenant ${SHAREPOINT_TENANT_ID}"
fi
if [ -n "$ENTRA_BEARER_TOKEN" ]; then
  find_document "What is the group grant sentinel phrase?" "pangolin-ledger-group" \
    "group-grant.txt is retrievable by a signed-in member of the group" "R19" "bearer:${ENTRA_BEARER_TOKEN}"
  find_document "Which document was shared with an organisation wide link?" "pangolin-ledger-orgwide" \
    "a signed-in Microsoft caller retrieves org-wide.txt" "R21" "bearer:${ENTRA_BEARER_TOKEN}"
else
  skip "R19 R21: set ENTRA_BEARER_TOKEN to a group member's access_as_user token to run them"
fi

echo
printf "${B}Passed: %d  Failed: %d  Skipped: %d${N}\n" "$PASS" "$FAIL" "$SKIP"
echo "Log: $LOG"
[ "$FAIL" -eq 0 ]
