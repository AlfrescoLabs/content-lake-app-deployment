#!/usr/bin/env bash
# test-rag-full.sh — Full-stack RAG suite for Alfresco + Nuxeo.
#
# Requires:
#   - sibling nuxeo-deployment running on http://localhost:8081
#   - content-lake-app-deployment running with STACK_MODE=full
#   - curl, jq, base64
#
# Verifies:
#   - both repositories are reachable through the local deployment
#   - Alfresco and Nuxeo content are indexed in full mode
#   - semantic, hybrid, and prompt RAG endpoints work with shared repository fixtures
#   - RAG accepts UI-style Alfresco tickets and Nuxeo authentication tokens
#
# Environment variables:
#   ALF_AUTH     Alfresco admin, user:password (default: admin:admin)
#   NUXEO_AUTH   Nuxeo admin, user:password (default: Administrator:Administrator)

set -uo pipefail

# Honor USE_HTTPS for proxy-fronted URLs: the nginx proxy 301-redirects http->https, so tests
# must target the same scheme the harness runs under. The direct Nuxeo port (8081) is not behind
# the proxy and stays http. The curl wrapper injects -k for the proxy's self-signed cert.
SCHEME="http"; CURL_TLS=""
if [ "${USE_HTTPS:-false}" = "true" ]; then SCHEME="https"; CURL_TLS="-k"; fi
curl() { command curl ${CURL_TLS} "$@"; }

ALF_BASE="${SCHEME}://localhost/alfresco/api/-default-/public/alfresco/versions/1"
ALF_TICKET_URL="${SCHEME}://localhost/alfresco/api/-default-/public/authentication/versions/1/tickets"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
NUXEO_BASE='http://localhost:8081/nuxeo/api/v1'
NUXEO_AUTH="${NUXEO_AUTH:-Administrator:Administrator}"
SYNC_URL="${SCHEME}://localhost/api/sync"
RAG_URL="${SCHEME}://localhost/api/rag"
SHARED_USER='rag-user'
SHARED_PASSWORD='password'

# The demo fixture script defaults BASE_URL to the content-lake proxy (http://localhost/nuxeo),
# which 301-redirects http->https and whose curl follows neither the redirect nor the self-signed
# cert. Point it at Nuxeo directly so fixture creation succeeds (mirrors test-nuxeo.sh).
export BASE_URL="${BASE_URL:-http://localhost:8081/nuxeo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_SCRIPT="$SCRIPT_DIR/../scripts/create-nuxeo-demo-file.sh"

PASS=0; FAIL=0
TMPDIR_DATA="$(mktemp -d)"
TEST_RUN_TAG="$(date +%Y%m%d-%H%M%S)-$$"
LOG="test-results-rag-full-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}─── %s ───${N}\n" "$*"; }

cleanup() { rm -rf "$TMPDIR_DATA"; }
trap cleanup EXIT

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

create_alfresco_user() {
  local id="$1"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$id\",\"firstName\":\"Rag\",\"lastName\":\"User\",\"email\":\"${id}@test.local\",\"password\":\"$SHARED_PASSWORD\"}")
  case "$code" in
    201) info "Created Alfresco user $id" ;;
    409) info "Alfresco user $id already exists" ;;
    *) fail "U1: Failed to create Alfresco user $id (HTTP $code)" ;;
  esac
}

create_nuxeo_user() {
  local id="$1"
  local check_code payload code
  check_code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
    "$NUXEO_BASE/user/$id" 2>/dev/null )
  case "$check_code" in
    200)
      info "Nuxeo user $id already exists"
      return 0
      ;;
    404)
      payload=$(cat <<EOF
{"entity-type":"user","id":"$id","name":"$id","properties":{"username":"$id","firstName":"Rag","lastName":"User","password":"$SHARED_PASSWORD","email":"${id}@test.local"}}
EOF
)
      code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
        "$NUXEO_BASE/user" \
        -H 'Content-Type: application/json' \
        --data "$payload" 2>/dev/null )
      case "$code" in
        200|201) info "Created Nuxeo user $id" ;;
        409) info "Nuxeo user $id already exists" ;;
        *) fail "U2: Failed to create Nuxeo user $id (HTTP $code)" ;;
      esac
      ;;
    *)
      fail "U2: Failed to check Nuxeo user $id (HTTP $check_code)"
      ;;
  esac
}

create_alfresco_folder() {
  local name="$1"
  local resp http_code body
  resp=$(curl -s -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/-my-/children" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"nodeType\":\"cm:folder\"}" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    curl -sf -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/-my-/children?fields=id,name&maxItems=500" 2>/dev/null \
      | jq -r --arg n "$name" '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

upload_alfresco_file() {
  local parent="$1" path="$2" name="$3"
  local resp http_code body
  resp=$(curl -s -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/$parent/children" \
    -F "filedata=@${path};type=text/plain" \
    -F "name=$name" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    curl -sf -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/$parent/children?fields=id,name&maxItems=500" 2>/dev/null \
      | jq -r --arg n "$name" '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

set_alfresco_read_access() {
  local node_id="$1" user_id="$2" code
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
    "$ALF_BASE/nodes/$node_id" \
    -H 'Content-Type: application/json' \
    -d "{\"permissions\":{\"isInheritanceEnabled\":false,\"locallySet\":[{\"authorityId\":\"$user_id\",\"name\":\"Consumer\",\"accessStatus\":\"ALLOWED\"}]}}" \
    2>/dev/null )
  [ "$code" = "200" ]
}

create_nuxeo_demo_file() {
  local title="$1" text="$2"
  local output
  output=$(bash "$DEMO_SCRIPT" --title "$title" --text "$text" 2>/dev/null) || return 1
  printf '%s' "$output" | awk '/^UID:/ {print $2}'
}

set_nuxeo_read_access() {
  local uid="$1" code payload
  payload=$(cat <<EOF
{"params":{"permission":"Read","users":["Administrator"],"blockInheritance":true},"input":"doc:$uid"}
EOF
)
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/automation/Document.AddPermission" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null )
  if [ "$code" != "200" ] && [ "$code" != "204" ]; then
    return 1
  fi

  payload=$(cat <<EOF
{"params":{"permission":"Read","users":["$SHARED_USER"],"blockInheritance":false},"input":"doc:$uid"}
EOF
)
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" -X POST \
    "$NUXEO_BASE/automation/Document.AddPermission" \
    -H 'Content-Type: application/json' \
    --data "$payload" 2>/dev/null )
  [ "$code" = "200" ] || [ "$code" = "204" ]
}

run_alfresco_sync_wait() {
  local folder_id="$1" resp job_id status
  resp=$(curl -sf -u "$ALF_AUTH" -X POST "$SYNC_URL/batch?sourceType=alfresco" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$folder_id\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  job_id=$(printf '%s' "$resp" | jq -r '.jobId // empty')
  if [ -z "$job_id" ]; then
    fail "S1: Alfresco sync trigger returned no jobId (response: $resp)"
    return 1
  fi
  pass "S1: Alfresco sync triggered (jobId=$job_id)"

  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local status_resp
    status_resp=$(curl -sf -u "$ALF_AUTH" "$SYNC_URL/status/$job_id?sourceType=alfresco" 2>/dev/null || echo '{}')
    status=$(printf '%s' "$status_resp" | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED)
        pass "S2: Alfresco sync completed"
        return 0
        ;;
      FAILED|ERROR)
        fail "S2: Alfresco sync failed ($status)"
        return 1
        ;;
    esac
    sleep 10
    elapsed=$((elapsed+10))
  done
  fail "S2: Alfresco sync timed out after 5 minutes"
  return 1
}

run_nuxeo_sync_wait() {
  local resp job_id status
  resp=$(curl -sf -u "$NUXEO_AUTH" -X POST "$SYNC_URL/configured?sourceType=nuxeo" 2>/dev/null || echo '{}')
  job_id=$(printf '%s' "$resp" | jq -r '.jobId // empty')
  if [ -z "$job_id" ]; then
    fail "S3: Nuxeo sync trigger returned no jobId (response: $resp)"
    return 1
  fi
  pass "S3: Nuxeo sync triggered (jobId=$job_id)"

  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local status_resp
    status_resp=$(curl -sf -u "$NUXEO_AUTH" "$SYNC_URL/status/$job_id?sourceType=nuxeo" 2>/dev/null || echo '{}')
    status=$(printf '%s' "$status_resp" | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED)
        pass "S4: Nuxeo sync completed"
        return 0
        ;;
      FAILED|ERROR)
        fail "S4: Nuxeo sync failed ($status)"
        return 1
        ;;
    esac
    sleep 10
    elapsed=$((elapsed+10))
  done
  fail "S4: Nuxeo sync timed out after 5 minutes"
  return 1
}

rag_semantic_basic() {
  local auth="$1" query="$2"
  curl -sf -u "$auth" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":$(json_escape "$query"),\"topK\":20,\"minScore\":0.2}" 2>/dev/null || echo '{}'
}

rag_semantic_alf_ticket() {
  local ticket="$1" query="$2" encoded
  encoded=$(printf '%s:' "$ticket" | base64 | tr -d '\n')
  curl -sf -X POST "$RAG_URL/search/semantic" \
    -H "Authorization: Basic $encoded" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":$(json_escape "$query"),\"topK\":20,\"minScore\":0.2}" 2>/dev/null || echo '{}'
}

rag_hybrid_basic() {
  local auth="$1" query="$2"
  curl -sf -u "$auth" -X POST "$RAG_URL/search/hybrid" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":$(json_escape "$query"),\"topK\":20}" 2>/dev/null || echo '{}'
}

# /api/rag/prompt takes "question"; the search endpoints take "query". Sending "query" here binds
# nothing, so the endpoint answers 400 "Question is required" and D6 fails with an empty answer -- which
# it did for months, and which was read as a symptom of the crowding in #100/#134 rather than as this.
# test-rag-advisor.sh has always had it right and its /prompt assertions have always passed, which is the
# comparison that gives it away.
rag_prompt_basic() {
  local auth="$1" question="$2"
  curl -sf -u "$auth" -X POST "$RAG_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d "{\"question\":$(json_escape "$question"),\"topK\":5}" 2>/dev/null || echo '{}'
}

assert_found() {
  local response="$1" node_id="$2" source_type="$3" tid="$4" label="$5"
  local found
  found=$(printf '%s' "$response" | jq --arg id "$node_id" --arg src "$source_type" \
    '[.results[]? | select(.sourceDocument.nodeId == $id and .sourceDocument.sourceType == $src)] | length' \
    2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found"
  else
    fail "$tid: $label not found"
    printf '    top results: %s\n' \
      "$(printf '%s' "$response" | jq -c '[.results[:5][]? | {id:.sourceDocument.nodeId, src:.sourceDocument.sourceType, score:.score}]' 2>/dev/null || echo '[]')"
  fi
}

assert_has_both_sources() {
  local response="$1" tid="$2" label="$3"
  local types
  types=$(printf '%s' "$response" | jq -r '[.results[]?.sourceDocument.sourceType] | unique | sort | join(",")' \
    2>/dev/null || echo "")
  if [ "$types" = "alfresco,nuxeo" ]; then
    pass "$tid: $label returned both source types"
  else
    fail "$tid: $label returned source types '$types' (expected alfresco,nuxeo)"
  fi
}

wait_for_result_basic() {
  local auth="$1" query="$2" node_id="$3" source_type="$4" tid="$5" label="$6"
  local attempt response found
  for attempt in $(seq 1 18); do
    response=$(rag_semantic_basic "$auth" "$query")
    found=$(printf '%s' "$response" | jq --arg id "$node_id" --arg src "$source_type" \
      '[.results[]? | select(.sourceDocument.nodeId == $id and .sourceDocument.sourceType == $src)] | length' \
      2>/dev/null || echo 0)
    if [ "${found:-0}" -gt 0 ]; then
      pass "$tid: $label indexed and searchable"
      return 0
    fi
    sleep 10
  done
  fail "$tid: $label did not appear within 3 minutes"
  return 1
}

get_alfresco_ticket() {
  local auth="$1" user_id password resp code body
  user_id="${auth%%:*}"
  password="${auth#*:}"
  resp=$(curl -s -w '\n%{http_code}' -X POST "$ALF_TICKET_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"userId\":\"$user_id\",\"password\":\"$password\"}" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  else
    echo ""
  fi
}

section "A — Smoke Tests"

code=$(curl -sf -o /dev/null -w '%{http_code}' "$RAG_URL/health" 2>/dev/null )
code="${code:-000}"
[ "$code" = "200" ] && pass "A1: RAG service /health is UP" || fail "A1: RAG service returned HTTP $code"

code=$(curl -sf -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  "$ALF_BASE/nodes/-root-/children" 2>/dev/null )
[ "$code" = "200" ] && pass "A2: Alfresco repository responds" || fail "A2: Alfresco returned HTTP $code"

code=$(curl -sf -o /dev/null -w '%{http_code}' -u "$NUXEO_AUTH" \
  "$NUXEO_BASE/path/default-domain" 2>/dev/null )
[ "$code" = "200" ] && pass "A3: Nuxeo repository responds" || fail "A3: Nuxeo returned HTTP $code"

unauth_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"unauthenticated","topK":1,"minScore":0.2}' 2>/dev/null )
[ "$unauth_code" = "401" ] \
  && pass "A4: Unauthenticated RAG request rejected with HTTP 401" \
  || fail "A4: Expected HTTP 401 for unauthenticated request, got HTTP $unauth_code"

section "B — Shared Principal Fixtures"

create_alfresco_user "$SHARED_USER"
create_nuxeo_user "$SHARED_USER"

AUTH_SHARED="$SHARED_USER:$SHARED_PASSWORD"
SHARED_QUERY="shared cross source rag sentinel cobalt-bridge-${TEST_RUN_TAG}"
ALF_QUERY="alfresco only rag sentinel cedar-harbor-${TEST_RUN_TAG}"
NUXEO_QUERY="nuxeo only rag sentinel amber-comet-${TEST_RUN_TAG}"

ALF_FOLDER_ID=$(create_alfresco_folder "content-lake-rag-full-$TEST_RUN_TAG")
if [ -n "$ALF_FOLDER_ID" ]; then
  pass "B1: Alfresco test folder ready (nodeId=$ALF_FOLDER_ID)"
else
  fail "B1: Failed to create Alfresco test folder"
fi

ALF_PATH="$TMPDIR_DATA/alfresco-rag-full-$TEST_RUN_TAG.txt"
cat > "$ALF_PATH" <<EOF
ALFRESCO FULL-STACK RAG TEST DOCUMENT

This document is readable by $SHARED_USER only.
Shared search phrase: $SHARED_QUERY.
Alfresco search phrase: $ALF_QUERY.
EOF

ALF_NODE_ID=""
if [ -n "${ALF_FOLDER_ID:-}" ]; then
  ALF_NODE_ID=$(upload_alfresco_file "$ALF_FOLDER_ID" "$ALF_PATH" "alfresco-rag-full-$TEST_RUN_TAG.txt")
  if [ -n "$ALF_NODE_ID" ] && set_alfresco_read_access "$ALF_NODE_ID" "$SHARED_USER"; then
    pass "B2: Alfresco fixture created and restricted to $SHARED_USER (nodeId=$ALF_NODE_ID)"
  else
    fail "B2: Failed to create or permission Alfresco fixture"
  fi
fi

NUXEO_UID=$(create_nuxeo_demo_file "Nuxeo Full-Stack RAG $TEST_RUN_TAG" \
  "NUXEO FULL-STACK RAG TEST DOCUMENT. This document is readable by $SHARED_USER only. Shared search phrase: $SHARED_QUERY. Nuxeo search phrase: $NUXEO_QUERY.")
if [ -n "$NUXEO_UID" ] && set_nuxeo_read_access "$NUXEO_UID"; then
  pass "B3: Nuxeo fixture created and restricted to $SHARED_USER (uid=$NUXEO_UID)"
else
  fail "B3: Failed to create or permission Nuxeo fixture"
fi

section "C — Indexing"

[ -n "${ALF_FOLDER_ID:-}" ] && run_alfresco_sync_wait "$ALF_FOLDER_ID"
run_nuxeo_sync_wait

[ -n "${ALF_NODE_ID:-}" ] && wait_for_result_basic "$AUTH_SHARED" "$ALF_QUERY" "$ALF_NODE_ID" "alfresco" "C1" "Alfresco fixture"
[ -n "${NUXEO_UID:-}" ] && wait_for_result_basic "$AUTH_SHARED" "$NUXEO_QUERY" "$NUXEO_UID" "nuxeo" "C2" "Nuxeo fixture"

section "D — RAG Service"

resp_semantic=$(rag_semantic_basic "$AUTH_SHARED" "$SHARED_QUERY")
[ -n "${ALF_NODE_ID:-}" ] && assert_found "$resp_semantic" "$ALF_NODE_ID" "alfresco" "D1" "Semantic search returns Alfresco fixture"
[ -n "${NUXEO_UID:-}" ] && assert_found "$resp_semantic" "$NUXEO_UID" "nuxeo" "D2" "Semantic search returns Nuxeo fixture"
assert_has_both_sources "$resp_semantic" "D3" "Semantic cross-source search"

resp_hybrid=$(rag_hybrid_basic "$AUTH_SHARED" "$SHARED_QUERY")
[ -n "${ALF_NODE_ID:-}" ] && assert_found "$resp_hybrid" "$ALF_NODE_ID" "alfresco" "D4" "Hybrid search returns Alfresco fixture"
[ -n "${NUXEO_UID:-}" ] && assert_found "$resp_hybrid" "$NUXEO_UID" "nuxeo" "D5" "Hybrid search returns Nuxeo fixture"

resp_prompt=$(rag_prompt_basic "$AUTH_SHARED" "$SHARED_QUERY")
prompt_answer=$(printf '%s' "$resp_prompt" | jq -r '.answer // empty' 2>/dev/null || echo "")
prompt_sources=$(printf '%s' "$resp_prompt" | jq -r '(.sources // []) | length' 2>/dev/null || echo 0)
if [ -n "$prompt_answer" ] && [ "${prompt_sources:-0}" -gt 0 ]; then
  pass "D6: Prompt endpoint returned an answer with sources"
else
  fail "D6: Prompt endpoint did not return a non-empty answer with sources"
fi

section "E — UI-Style Authentication"

ALF_TICKET=$(get_alfresco_ticket "$AUTH_SHARED")
if [ -n "$ALF_TICKET" ]; then
  pass "E1: Alfresco ticket acquired for $SHARED_USER"
  ticket_resp=$(rag_semantic_alf_ticket "$ALF_TICKET" "$SHARED_QUERY")
  [ -n "${ALF_NODE_ID:-}" ] && assert_found "$ticket_resp" "$ALF_NODE_ID" "alfresco" "E2" "Alfresco ticket auth returns Alfresco fixture"
  [ -n "${NUXEO_UID:-}" ] && assert_found "$ticket_resp" "$NUXEO_UID" "nuxeo" "E3" "Alfresco ticket auth returns Nuxeo fixture"
  assert_has_both_sources "$ticket_resp" "E4" "Alfresco ticket cross-source search"
else
  fail "E1: Failed to acquire Alfresco ticket for $SHARED_USER"
fi

# E5-E8: rag-user is a Nuxeo user. rag-service authenticates Nuxeo users over HTTP Basic
# (validated against GET /nuxeo/api/v1/me), so we exercise that path directly rather than a Nuxeo
# auth token (token auth is not enabled in this stack). A valid, ACL-scoped result set proves the
# Nuxeo-user Basic auth path works end to end.
basic_resp=$(rag_semantic_basic "$AUTH_SHARED" "$SHARED_QUERY")
if printf '%s' "$basic_resp" | jq -e 'has("results")' >/dev/null 2>&1; then
  pass "E5: rag-user (Nuxeo user) authenticated to rag-service via Basic auth"
  [ -n "${ALF_NODE_ID:-}" ] && assert_found "$basic_resp" "$ALF_NODE_ID" "alfresco" "E6" "Nuxeo-user Basic auth returns Alfresco fixture"
  [ -n "${NUXEO_UID:-}" ] && assert_found "$basic_resp" "$NUXEO_UID" "nuxeo" "E7" "Nuxeo-user Basic auth returns Nuxeo fixture"
  assert_has_both_sources "$basic_resp" "E8" "Nuxeo-user Basic cross-source search"
else
  fail "E5: rag-user Basic-auth semantic search returned no authenticated result"
fi

section "Summary"
printf "Passed: %d | Failed: %d\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
