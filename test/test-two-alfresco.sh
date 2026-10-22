#!/usr/bin/env bash
# CURL_OPTS is either empty or "-k" and is expanded unquoted on purpose, as in the other suites (SC2086,
# SC2206). Per-repository variables are read through rv() and written with printf -v, which shellcheck
# cannot follow (SC2034, SC2153).
# shellcheck disable=SC2086,SC2206,SC2034,SC2153
# test-two-alfresco.sh - two Alfresco repositories in one Content Lake: isolated, and still answering one
# question together.
#
# Runs against the alfresco-2 profile. Seeds the same users in both repositories with different groups,
# a same-named group with different members in each, and one fixture document per case, then asserts:
#
#   X   cross-source answer   a user in Sales in both gets both Sales documents, each with its own sourceId
#   G   groups per source     Finance membership in A does not open B's Finance document, and the
#                             same-named Sales group resolves to each repository's own members
#   L   login per source      plain Basic gives a name only where the password is accepted, and
#                             X-Source-Authorization carries a different password per repository
#   A   admin bypass          an administrator of A only sees all of A and nothing extra of B
#   D   deletion isolation    a document deleted in B leaves A's same-named document in place, also after a
#                             reconciling sync on B
#   P   ACL change not lost   ACLs changed in A and in B within one second both reach the index
#   K   links                 each result's openInSourceUrl opens in its own repository's ACA
#
# Opt-in, and not a phase of run-tests.sh: the alfresco-2 profile is opt-in and roughly doubles the stack,
# so wiring it into every run would make the whole suite pay for a second repository.
#
# Prerequisites:
#   - `make up-alfresco-2` already up and healthy, with ALFRESCO_1_SOURCE_ID and ALFRESCO_2_SOURCE_ID set to
#     the two repository ids, so rag-service lists both sources. T0 checks this and stops otherwise.
#   - the AI backend on :12434, since ingestion embeds
#   - curl, jq
#
# Usage:
#   ./test/test-two-alfresco.sh
#   RAG_SECURITY_ADMIN_BYPASS_ENABLED=false ./test/test-two-alfresco.sh   # rag-service runs without bypass
#
# Environment variables:
#   HOST                    Target host (default: localhost)
#   USE_HTTPS               "true" to use https and pass -k to curl (default: false)
#   ALF_AUTH                Admin of the first repository, user:password (default: admin:admin)
#   ALF2_AUTH               Admin of the second repository, user:password (default: admin:admin)
#   RAG_AUTH                Credentials for the rag-service health probe (default: ALF_AUTH)
#   PUBLIC_PORT             Public port of the first instance (default: 80, or 443 with USE_HTTPS)
#   ALFRESCO_2_PUBLIC_PORT  Public HTTP port of the second instance (default: 8082)
#   ALFRESCO_2_HTTPS_PORT   Public HTTPS port of the second instance (default: 8445)
#   RAG_SECURITY_ADMIN_BYPASS_ENABLED
#                           What the running rag-service has. The deployment default is true. Set it to
#                           anything else and the A-series is skipped with a note (default: true)
#   POLL_DEADLINE_S         Seconds to wait for a document to reach the index (default: 60)
#   ACL_DEADLINE_S          Seconds to wait for the P3 ACL changes; see the comment at P3 (default: 240)
#   SYNC_DEADLINE_S         Seconds to wait for a sync job to complete (default: 60)
#   INDEX_WAIT_S            Seconds to wait for Alfresco's own search index before a sync (default: 60)
#   SEARCH_MAX_RESULTS      maxResults on each hybrid search (default: 20)
#   KEEP_DATA               "true" to leave the seeded folders, users and groups in place (default: false)

set -uo pipefail

HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-false}"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
ALF2_AUTH="${ALF2_AUTH:-admin:admin}"
RAG_AUTH="${RAG_AUTH:-$ALF_AUTH}"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-60}"
ACL_DEADLINE_S="${ACL_DEADLINE_S:-240}"
SYNC_DEADLINE_S="${SYNC_DEADLINE_S:-60}"
INDEX_WAIT_S="${INDEX_WAIT_S:-60}"
SEARCH_MAX_RESULTS="${SEARCH_MAX_RESULTS:-20}"
KEEP_DATA="${KEEP_DATA:-false}"
ADMIN_BYPASS="${RAG_SECURITY_ADMIN_BYPASS_ENABLED:-true}"

if [ "${USE_HTTPS}" = "true" ]; then
  A_PORT="${PUBLIC_PORT:-443}"
  B_PORT="${ALFRESCO_2_HTTPS_PORT:-8445}"
  A_BASE="https://${HOST}:${A_PORT}"
  B_BASE="https://${HOST}:${B_PORT}"
  CURL_OPTS="-k"
else
  A_PORT="${PUBLIC_PORT:-80}"
  B_PORT="${ALFRESCO_2_PUBLIC_PORT:-8082}"
  A_BASE="http://${HOST}:${A_PORT}"
  B_BASE="http://${HOST}:${B_PORT}"
  CURL_OPTS=""
fi
# readiness.sh reads CURL_TLS.
CURL_TLS="$CURL_OPTS"

# Per-repository settings, read through rv() so every helper takes the repository letter, A or B.
A_API="${A_BASE}/alfresco/api/-default-/public/alfresco/versions/1"
B_API="${B_BASE}/alfresco/api/-default-/public/alfresco/versions/1"
A_AUTH="$ALF_AUTH"
B_AUTH="$ALF2_AUTH"
# Each port routes /api/sync to its own batch ingester (nginx/alfresco-2.conf.template).
A_SYNC="${A_BASE}/api/sync"
B_SYNC="${B_BASE}/api/sync"
# One rag-service behind both ports.
RAG_URL="${A_BASE}/api/rag"

rv() { local v="${1}_$2"; printf '%s' "${!v}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/readiness.sh
. "${SCRIPT_DIR}/lib/readiness.sh"

TMP="$(mktemp -d)"
BODY="${TMP}/body.json"
LOG="test-results-two-alfresco-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0; SKIP=0
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
skip()    { printf "${Y}[SKIP]${N} %s\n" "$*"; SKIP=$((SKIP+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}--- %s ---${N}\n" "$*"; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 2; }
done

# Alphanumeric only, so it is valid in user ids, group ids and file names, and is one token to the
# keyword half of hybrid search.
RUN_TAG="tw$(date +%m%d%H%M%S)$$"

# Seeded objects, recorded as they are created so cleanup removes exactly these.
A_USERS=""; B_USERS=""; A_GROUPS=""; B_GROUPS=""
A_FOLDER=""; B_FOLDER=""
ADM_PROMOTED=0

summary() {
  printf "\n${B}Two-Alfresco suite: ${G}%d passed${N}, ${R}%d failed${N}, ${Y}%d skipped${N}\n" \
    "$PASS" "$FAIL" "$SKIP"
  printf "Log: %s\n" "$LOG"
}

# --- HTTP helpers ------------------------------------------------------------------------------------

# alf_req <repo> <method> <path> [json] : prints the HTTP code, leaves the body in $BODY.
alf_req() {
  local r="$1" m="$2" p="$3" d="${4:-}"
  local args=(-s $CURL_OPTS -o "$BODY" -w '%{http_code}' -u "$(rv "$r" AUTH)" -X "$m" "$(rv "$r" API)$p")
  [ -n "$d" ] && args+=(-H 'Content-Type: application/json' -d "$d")
  : > "$BODY"
  curl "${args[@]}" 2>/dev/null || true
}

# rag_search <query> [curl auth args...] : sets RESP and RESP_CODE. Call it directly, never in $(...),
# or both are lost with the subshell.
RESP=""; RESP_CODE=""
rag_search() {
  local q="$1"; shift
  local payload out
  payload=$(jq -nc --arg q "$q" --argjson m "$SEARCH_MAX_RESULTS" '{query:$q, maxResults:$m}')
  out=$(curl $CURL_OPTS -s -w '\n%{http_code}' "$@" -X POST "${RAG_URL}/search/hybrid" \
    -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
  RESP_CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

# hit <node_id> <repo_id> : the last response holds this node from this repository. The source id is the
# qualified alfresco:<repoId>; the bare id is accepted too, so a format change reads as a label failure in
# X1 rather than as every presence check failing.
hit() {
  printf '%s' "$RESP" | jq -e --arg n "$1" --arg r "$2" \
    '[.results[]? | .sourceDocument | select(.nodeId == $n
        and (((.sourceId // "") == $r) or ((.sourceId // "") | endswith(":" + $r))))] | length > 0' \
    >/dev/null 2>&1
}

show_top() {
  local top
  top=$(printf '%s' "$RESP" | jq -c '[.results[:5][] | .sourceDocument | {name, nodeId, sourceId}]' 2>/dev/null)
  if [ -n "$top" ]; then
    echo "    top results: ${top}"
  else
    echo "    HTTP ${RESP_CODE:-none}, body (first 300 bytes): $(printf '%s' "$RESP" | head -c 300)"
  fi
}

# source_header <repo_id> <user> <password> : one X-Source-Authorization value.
source_header() {
  printf '%s Basic %s' "alfresco:$1" "$(printf '%s:%s' "$2" "$3" | base64 | tr -d '\n')"
}

# expect_present <tid> <label> <query> <node> <repo_id> [curl auth args...]
expect_present() {
  local tid="$1" label="$2" query="$3" node="$4" repo="$5"; shift 5
  local waited=0
  while :; do
    rag_search "$query" "$@"
    if [ "$RESP_CODE" = "200" ] && hit "$node" "$repo"; then
      pass "${tid}: ${label} (after ${waited}s)"
      return 0
    fi
    [ "$waited" -ge "$POLL_DEADLINE_S" ] && break
    sleep 5; waited=$((waited+5))
  done
  fail "${tid}: ${label}: not retrievable after ${waited}s (node ${node}, source ${repo})"
  show_top
  return 1
}

# expect_present_pair <tid> <label> <query> <node1> <repo1> <node2> <repo2> [curl auth args...]
# One query, one deadline, both documents in the same response.
expect_present_pair() {
  local tid="$1" label="$2" query="$3" n1="$4" r1="$5" n2="$6" r2="$7"; shift 7
  local waited=0 seen1 seen2
  while :; do
    rag_search "$query" "$@"
    seen1=0; seen2=0
    if [ "$RESP_CODE" = "200" ]; then
      hit "$n1" "$r1" && seen1=1
      hit "$n2" "$r2" && seen2=1
    fi
    if [ "$seen1" = "1" ] && [ "$seen2" = "1" ]; then
      pass "${tid}: ${label} (after ${waited}s)"
      return 0
    fi
    [ "$waited" -ge "$POLL_DEADLINE_S" ] && break
    sleep 5; waited=$((waited+5))
  done
  fail "${tid}: ${label}: after ${waited}s first=${seen1} (node ${n1}) second=${seen2} (node ${n2})"
  show_top
  return 1
}

# expect_absent <tid> <label> <query> <node> <repo_id> [curl auth args...]
# One search, no deadline: every call site comes after a presence check that proved the document is
# retrievable by someone. Matched on the node id and source id, which only this document has. A non-200
# response is a failure, since an error body would satisfy any absence.
expect_absent() {
  local tid="$1" label="$2" query="$3" node="$4" repo="$5"; shift 5
  rag_search "$query" "$@"
  if [ "$RESP_CODE" != "200" ]; then
    fail "${tid}: ${label}: search answered HTTP ${RESP_CODE:-none}, so absence cannot be judged"
    show_top
    return 1
  fi
  if hit "$node" "$repo"; then
    fail "${tid}: ${label}: the document IS returned (node ${node}, source ${repo})"
    show_top
    return 1
  fi
  pass "${tid}: ${label}"
}

# expect_code <tid> <label> <want> <query> [curl auth args...]
expect_code() {
  local tid="$1" label="$2" want="$3" query="$4"; shift 4
  rag_search "$query" "$@"
  if [ "$RESP_CODE" = "$want" ]; then
    pass "${tid}: ${label} (HTTP ${RESP_CODE})"
  else
    fail "${tid}: ${label}: expected HTTP ${want}, got ${RESP_CODE:-none}"
  fi
}

# --- Seeding helpers ---------------------------------------------------------------------------------

# create_user <repo> <id> <password>
create_user() {
  local r="$1" id="$2" pw="$3" code
  code=$(alf_req "$r" POST /people "$(jq -nc --arg id "$id" --arg pw "$pw" \
    '{id:$id, firstName:"Two", lastName:"Alfresco", email:($id + "@test.local"), password:$pw}')")
  case "$code" in
    201) printf -v "${r}_USERS" '%s %s' "$(rv "$r" USERS)" "$id"; return 0 ;;
    *)   fail "S1: creating user ${id} in ${r} answered HTTP ${code}: $(head -c 200 "$BODY")"; return 1 ;;
  esac
}

# create_group <repo> <short_id> : authority is GROUP_<short_id>.
create_group() {
  local r="$1" id="$2" code
  code=$(alf_req "$r" POST /groups "$(jq -nc --arg id "$id" '{id:$id, displayName:$id}')")
  case "$code" in
    201) printf -v "${r}_GROUPS" '%s %s' "$(rv "$r" GROUPS)" "GROUP_${id}"; return 0 ;;
    *)   fail "S2: creating group ${id} in ${r} answered HTTP ${code}: $(head -c 200 "$BODY")"; return 1 ;;
  esac
}

# add_member <repo> <group_authority> <user>
add_member() {
  local r="$1" grp="$2" user="$3" code
  code=$(alf_req "$r" POST "/groups/${grp}/members" "$(jq -nc --arg id "$user" '{id:$id, memberType:"PERSON"}')")
  [ "$code" = "201" ] && return 0
  fail "S2: adding ${user} to ${grp} in ${r} answered HTTP ${code}: $(head -c 200 "$BODY")"
  return 1
}

# create_folder <repo> <name> : under Company Home. Prints the node id.
create_folder() {
  local r="$1" name="$2" code
  code=$(alf_req "$r" POST /nodes/-root-/children "$(jq -nc --arg n "$name" '{name:$n, nodeType:"cm:folder"}')")
  [ "$code" = "201" ] && jq -r '.entry.id // empty' "$BODY"
}

# acl_json <authority...> : Consumer for each, inheritance off, so a document is readable by exactly these.
acl_json() {
  printf '%s\n' "$@" | jq -R . | jq -sc \
    '{permissions:{isInheritanceEnabled:false,
                   locallySet:[.[] | {authorityId:., name:"Consumer", accessStatus:"ALLOWED"}]}}'
}

# seed_doc <repo> <var> <file_name> <text> <authority...>
# Uploads one document into the repository's test folder and sets its ACL. The node id goes to <var>.
# The ACL is set before the first sync on purpose, so the first ingestion already carries it.
SEEDED=0
seed_doc() {
  local r="$1" var="$2" name="$3" text="$4"; shift 4
  local file="${TMP}/${r}-${name}" folder code id
  folder=$(rv "$r" FOLDER)
  printf '%s\n' "$text" > "$file"
  : > "$BODY"
  code=$(curl -s $CURL_OPTS -o "$BODY" -w '%{http_code}' -u "$(rv "$r" AUTH)" -X POST \
    "$(rv "$r" API)/nodes/${folder}/children" \
    -F "filedata=@${file};type=text/plain" -F "name=${name}" 2>/dev/null || true)
  id=$(jq -r '.entry.id // empty' "$BODY" 2>/dev/null)
  if [ "$code" != "201" ] || [ -z "$id" ]; then
    fail "S4: uploading ${name} to ${r} answered HTTP ${code}: $(head -c 200 "$BODY")"
    return 1
  fi
  printf -v "$var" '%s' "$id"
  code=$(alf_req "$r" PUT "/nodes/${id}" "$(acl_json "$@")")
  if [ "$code" != "200" ]; then
    fail "S4: setting the ACL of ${name} in ${r} answered HTTP ${code}: $(head -c 200 "$BODY")"
    return 1
  fi
  SEEDED=$((SEEDED+1))
}

# --- Sync helpers ------------------------------------------------------------------------------------

# wait_afts <repo> <folder> <expected> : batch discovery is an AFTS ANCESTOR query against Alfresco's own
# search index, which lags uploads. Syncing before it catches up discovers nothing. Same query shape as
# wait_for_solr_indexed in test-alfresco.sh.
wait_afts() {
  local r="$1" folder="$2" want="$3" waited=0 found=0
  local url
  url="$(rv "$r" BASE)/alfresco/api/-default-/public/search/versions/1/search"
  while :; do
    found=$(curl -s $CURL_OPTS -u "$(rv "$r" AUTH)" -X POST "$url" -H 'Content-Type: application/json' \
      -d "{\"query\":{\"language\":\"afts\",\"query\":\"ANCESTOR:'workspace://SpacesStore/${folder}' AND TYPE:'cm:content'\"},\"paging\":{\"maxItems\":100}}" \
      2>/dev/null | jq -r '.list.pagination.totalItems // 0' 2>/dev/null || echo 0)
    [ "${found:-0}" -ge "$want" ] && { info "${r}: Alfresco search sees ${found}/${want} documents"; return 0; }
    [ "$waited" -ge "$INDEX_WAIT_S" ] && break
    sleep 5; waited=$((waited+5))
  done
  info "${r}: Alfresco search sees only ${found:-0}/${want} documents after ${waited}s; syncing anyway"
  return 0
}

# start_sync <repo> <folder> <var> : the job id goes to <var>, empty when the trigger failed. A folder sync
# also adds cl:indexed to the folder, which is what puts it in ingestion scope.
start_sync() {
  local r="$1" folder="$2" var="$3" resp
  resp=$(curl -s $CURL_OPTS -u "$(rv "$r" AUTH)" -X POST "$(rv "$r" SYNC)/batch" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"${folder}\"],\"recursive\":true,\"types\":[\"cm:content\"]}" 2>/dev/null || echo '{}')
  printf -v "$var" '%s' "$(printf '%s' "$resp" | jq -r '.jobId // empty' 2>/dev/null)"
  if [ -z "${!var}" ]; then
    echo "    ${r} sync trigger response: $(printf '%s' "$resp" | head -c 300)"
  fi
}

# wait_sync <repo> <job_id> : 0 when COMPLETED. The final status JSON is left in $BODY.
wait_sync() {
  local r="$1" job="$2" waited=0 st=""
  while :; do
    curl -s $CURL_OPTS -o "$BODY" -u "$(rv "$r" AUTH)" "$(rv "$r" SYNC)/status/${job}" 2>/dev/null || true
    st=$(jq -r '.status // "UNKNOWN"' "$BODY" 2>/dev/null || echo UNKNOWN)
    case "$st" in COMPLETED) return 0 ;; FAILED|ERROR) return 1 ;; esac
    [ "$waited" -ge "$SYNC_DEADLINE_S" ] && return 1
    sleep 5; waited=$((waited+5))
  done
}

# --- Cleanup -----------------------------------------------------------------------------------------

delete_user() {
  local r="$1" id="$2" code
  code=$(alf_req "$r" DELETE "/people/${id}")
  [ "$code" = "204" ] && return 0
  # The v1 API answers 405 on Community Edition; the legacy web script deletes the person.
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$(rv "$r" AUTH)" -X DELETE \
    "$(rv "$r" BASE)/alfresco/s/api/people/${id}" 2>/dev/null || true)
  [ "$code" = "200" ] || [ "$code" = "204" ] || info "could not delete user ${id} in ${r} (HTTP ${code})"
}

cleanup() {
  if [ "$KEEP_DATA" = "true" ]; then
    info "KEEP_DATA=true: seeded folders, users and groups left in place (tag ${RUN_TAG})"
  else
    info "Removing seeded content (tag ${RUN_TAG})"
    # The administrator grant first: a user that cannot be deleted must not stay an administrator.
    [ "$ADM_PROMOTED" = "1" ] && alf_req A DELETE "/groups/GROUP_ALFRESCO_ADMINISTRATORS/members/${U_ADM}" >/dev/null
    local r g u f
    for r in A B; do
      f=$(rv "$r" FOLDER)
      [ -n "$f" ] && alf_req "$r" DELETE "/nodes/${f}?permanent=true" >/dev/null
      for g in $(rv "$r" GROUPS); do alf_req "$r" DELETE "/groups/${g}?cascade=true" >/dev/null; done
      for u in $(rv "$r" USERS); do delete_user "$r" "$u"; done
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# === T0: preflight ===================================================================================
section "T0 Preflight"

repo_id() {
  curl -s $CURL_OPTS -u "$(rv "$1" AUTH)" "$(rv "$1" BASE)/alfresco/api/discovery" 2>/dev/null \
    | jq -r '.entry.repository.id // empty' 2>/dev/null
}
REPO_A=$(repo_id A)
REPO_B=$(repo_id B)
if [ -z "$REPO_A" ]; then
  fail "T0a: ${A_BASE}/alfresco/api/discovery is not reachable with ALF_AUTH. Is the stack up?"
  summary; exit 1
fi
pass "T0a: first repository reachable (id ${REPO_A})"
if [ -z "$REPO_B" ]; then
  fail "T0b: ${B_BASE}/alfresco/api/discovery is not reachable with ALF2_AUTH. Start it with make up-alfresco-2"
  summary; exit 1
fi
pass "T0b: second repository reachable (id ${REPO_B})"

if [ "$REPO_A" = "$REPO_B" ]; then
  fail "T0c: both repositories report id ${REPO_A}. The second was started from a copy of the first one's"
  echo "    volumes, so the two sources cannot be told apart. Run make clean and start again."
  summary; exit 1
fi
pass "T0c: the repository ids differ"

SID_A="alfresco:${REPO_A}"
SID_B="alfresco:${REPO_B}"
sources=$(curl -s $CURL_OPTS "${RAG_URL}/sources" 2>/dev/null || echo '[]')
listed=$(printf '%s' "$sources" | jq -r '[.[]? | select(.sourceType == "alfresco") | .sourceId] | sort | join(" ")' \
  2>/dev/null || echo "")
expected=$(printf '%s\n%s\n' "$SID_A" "$SID_B" | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$listed" = "$expected" ]; then
  pass "T0d: /api/rag/sources lists exactly the two repositories (${expected})"
else
  fail "T0d: /api/rag/sources lists alfresco sources '${listed}', expected '${expected}'"
  echo "    Set ALFRESCO_1_SOURCE_ID=${REPO_A} and ALFRESCO_2_SOURCE_ID=${REPO_B} in .env.local and run"
  echo "    make up-alfresco-2 again, which recreates rag-service. Response: $(printf '%s' "$sources" | head -c 300)"
  summary; exit 1
fi

if wait_rag_up "$A_BASE" "$RAG_AUTH" 12 5; then
  pass "T0e: rag-service health is UP"
else
  fail "T0e: rag-service health is not UP after 60s"
  summary; exit 1
fi

# === Seed ============================================================================================
section "Seed (tag ${RUN_TAG})"

PW="password"
U_SALES="tw-sales-${RUN_TAG}"   # both; G_SALES in both; G_FIN in B only
U_FIN="tw-fin-${RUN_TAG}"       # both; G_FIN in A only; G_SALES in A only
U_BONLY="tw-bonly-${RUN_TAG}"   # B only
U_DUAL="tw-dual-${RUN_TAG}"     # both, with a different password in each
U_ADM="tw-adm-${RUN_TAG}"       # both; administrator in A only
U_ACL="tw-acl-${RUN_TAG}"       # both; the grantee the ACL change moves documents to
PW_DUAL_A="pwA${RUN_TAG}"
PW_DUAL_B="pwB${RUN_TAG}"
G_SALES="G_SALES_${RUN_TAG}"
G_FIN="G_FIN_${RUN_TAG}"

seed_ok=1
for r in A B; do
  create_user "$r" "$U_SALES" "$PW" || seed_ok=0
  create_user "$r" "$U_FIN" "$PW"   || seed_ok=0
  create_user "$r" "$U_ADM" "$PW"   || seed_ok=0
  create_user "$r" "$U_ACL" "$PW"   || seed_ok=0
done
create_user A "$U_DUAL" "$PW_DUAL_A" || seed_ok=0
create_user B "$U_DUAL" "$PW_DUAL_B" || seed_ok=0
create_user B "$U_BONLY" "$PW"       || seed_ok=0
[ "$seed_ok" = "1" ] && pass "S1: users created (same ids in both, ${U_BONLY} in B only, ${U_DUAL} with two passwords)"

for r in A B; do
  create_group "$r" "$G_SALES" || seed_ok=0
  create_group "$r" "$G_FIN"   || seed_ok=0
done
add_member A "GROUP_${G_SALES}" "$U_SALES" || seed_ok=0
add_member A "GROUP_${G_SALES}" "$U_FIN"   || seed_ok=0
add_member A "GROUP_${G_FIN}"   "$U_FIN"   || seed_ok=0
add_member B "GROUP_${G_SALES}" "$U_SALES" || seed_ok=0
add_member B "GROUP_${G_FIN}"   "$U_SALES" || seed_ok=0
if add_member A GROUP_ALFRESCO_ADMINISTRATORS "$U_ADM"; then ADM_PROMOTED=1; else seed_ok=0; fi
[ "$seed_ok" = "1" ] && pass "S2: groups created; ${G_SALES} has different members in A and B; ${U_ADM} administers A only"

A_FOLDER=$(create_folder A "two-alfresco-${RUN_TAG}")
B_FOLDER=$(create_folder B "two-alfresco-${RUN_TAG}")
if [ -n "$A_FOLDER" ] && [ -n "$B_FOLDER" ]; then
  pass "S3: test folders created (A ${A_FOLDER}, B ${B_FOLDER})"
else
  fail "S3: could not create the test folders (A '${A_FOLDER}', B '${B_FOLDER}')"
  seed_ok=0
fi

# One document per case and repository. Each carries a distinct topic and a word no other fixture has, so a
# per-document query ranks it first; the run tag keeps a previous run's leftovers out of the presence checks.
DEL_NAME="retention-policy-${RUN_TAG}.txt"
if [ -n "$A_FOLDER" ] && [ -n "$B_FOLDER" ]; then
  seed_doc A SALES_A "sales-${RUN_TAG}.txt" \
    "Sales forecast ${RUN_TAG} for the Andromeda kettle line in the northern region: kestrel accounts grow." \
    "GROUP_${G_SALES}" || seed_ok=0
  seed_doc B SALES_B "sales-${RUN_TAG}.txt" \
    "Sales forecast ${RUN_TAG} for the Andromeda kettle line in the southern region: heron accounts shrink." \
    "GROUP_${G_SALES}" || seed_ok=0
  seed_doc A FIN_A "finance-${RUN_TAG}.txt" \
    "Finance ledger ${RUN_TAG}: the Lisbon office booked a provision for copper futures." \
    "GROUP_${G_FIN}" || seed_ok=0
  seed_doc B FIN_B "finance-${RUN_TAG}.txt" \
    "Finance ledger ${RUN_TAG}: the Oslo office wrote down a loan to a ferry operator." \
    "GROUP_${G_FIN}" || seed_ok=0
  seed_doc A PUB_A "notice-${RUN_TAG}.txt" \
    "Public notice ${RUN_TAG}: the cafeteria on floor nine serves cardamom buns on Fridays." \
    GROUP_EVERYONE || seed_ok=0
  seed_doc B BONLY_B "field-report-${RUN_TAG}.txt" \
    "Field report ${RUN_TAG}: the lighthouse at Point Varga needs a new Fresnel lens." \
    "$U_BONLY" || seed_ok=0
  seed_doc A DUAL_A "maintenance-${RUN_TAG}.txt" \
    "Maintenance note ${RUN_TAG}: the tram depot in Graz replaced its pantograph springs." \
    "$U_DUAL" || seed_ok=0
  seed_doc B DUAL_B "maintenance-${RUN_TAG}.txt" \
    "Maintenance note ${RUN_TAG}: the cable car in Bolzano replaced its brake pads." \
    "$U_DUAL" || seed_ok=0
  seed_doc A ADM_A "board-${RUN_TAG}.txt" \
    "Board minutes ${RUN_TAG}: the acquisition of a violin workshop in Cremona was approved." \
    "$U_SALES" || seed_ok=0
  seed_doc B ADM_B "board-${RUN_TAG}.txt" \
    "Board minutes ${RUN_TAG}: the sale of a vineyard in Tokaj was postponed." \
    "$U_SALES" || seed_ok=0
  seed_doc A ACL_A "audit-${RUN_TAG}.txt" \
    "Audit memo ${RUN_TAG}: the warehouse in Gdansk counted pallets of birch plywood." \
    "$U_SALES" || seed_ok=0
  seed_doc B ACL_B "audit-${RUN_TAG}.txt" \
    "Audit memo ${RUN_TAG}: the warehouse in Antwerp counted pallets of cork tiles." \
    "$U_SALES" || seed_ok=0
  seed_doc A DEL_A "$DEL_NAME" \
    "Retention policy ${RUN_TAG}: invoices from the Ghent branch are kept for eleven years." \
    GROUP_EVERYONE || seed_ok=0
  seed_doc B DEL_B "$DEL_NAME" \
    "Retention policy ${RUN_TAG}: invoices from the Porto branch are kept for seven years." \
    GROUP_EVERYONE || seed_ok=0
fi
PER_REPO=7
[ "$seed_ok" = "1" ] && pass "S4: ${SEEDED} documents uploaded with their ACLs (${PER_REPO} per repository)"

if [ "$seed_ok" != "1" ]; then
  fail "S: seeding failed, so no case below could be judged"
  summary; exit 1
fi

# === Sync ============================================================================================
section "Sync both repositories"

wait_afts A "$A_FOLDER" "$PER_REPO"
wait_afts B "$B_FOLDER" "$PER_REPO"

# sync_both : triggers both before waiting on either, so the two jobs overlap.
sync_both() {
  local tid="$1" r job ingested all_ok=0
  start_sync A "$A_FOLDER" JOB_A
  start_sync B "$B_FOLDER" JOB_B
  for r in A B; do
    job=$(rv JOB "$r")
    if [ -z "$job" ]; then
      fail "${tid}: ${r} sync did not start"; all_ok=1; continue
    fi
    if wait_sync "$r" "$job"; then
      ingested=$(jq -r '.metadataIngestedCount // 0' "$BODY" 2>/dev/null || echo 0)
      printf -v "INGESTED_${r}" '%s' "$ingested"
      pass "${tid}: ${r} sync ${job} COMPLETED (metadataIngestedCount=${ingested})"
    else
      fail "${tid}: ${r} sync ${job} did not complete in ${SYNC_DEADLINE_S}s: $(jq -c . "$BODY" 2>/dev/null | head -c 300)"
      all_ok=1
    fi
  done
  return "$all_ok"
}
INGESTED_A=0; INGESTED_B=0
sync_both "S5"
# The first sync adds cl:indexed to the folder, and Alfresco's index can still lag behind the uploads, so a
# short count gets one more pass, as in test-alfresco.sh R1b.
if [ "${INGESTED_A:-0}" -lt "$PER_REPO" ] || [ "${INGESTED_B:-0}" -lt "$PER_REPO" ]; then
  info "A ingested ${INGESTED_A}, B ingested ${INGESTED_B} of ${PER_REPO}; waiting for Alfresco search and syncing once more"
  wait_afts A "$A_FOLDER" "$PER_REPO"
  wait_afts B "$B_FOLDER" "$PER_REPO"
  sync_both "S6"
fi

# === X: cross-source answer ==========================================================================
section "X Cross-source answer"
expect_present_pair "X1" "${U_SALES} (Sales in both) gets the Sales document of A and of B, each with its own sourceId" \
  "Andromeda kettle sales forecast northern southern region ${RUN_TAG}" \
  "$SALES_A" "$REPO_A" "$SALES_B" "$REPO_B" -u "${U_SALES}:${PW}"
X1_RESP="$RESP"

# The label itself, exact: a result labelled with the other repository's id would also fail hit() above,
# but this names what is wrong.
labels=$(printf '%s' "$X1_RESP" | jq -r --arg a "$SALES_A" --arg b "$SALES_B" \
  '[.results[]? | .sourceDocument | select(.nodeId == $a or .nodeId == $b) | "\(.nodeId)=\(.sourceId)"] | unique | join(" ")' \
  2>/dev/null)
if printf '%s' "$labels" | grep -q "${SALES_A}=${SID_A}" && printf '%s' "$labels" | grep -q "${SALES_B}=${SID_B}"; then
  pass "X2: results carry sourceId ${SID_A} and ${SID_B}"
else
  fail "X2: expected ${SALES_A}=${SID_A} and ${SALES_B}=${SID_B}, got '${labels}'"
fi

# === K: links ========================================================================================
section "K Links"
# The port of a URL's origin, or the scheme default.
port_of() {
  local url="$1" hostport
  hostport="${url#*://}"; hostport="${hostport%%/*}"
  case "$hostport" in
    *:*) printf '%s' "${hostport##*:}" ;;
    *)   case "$url" in https:*) printf 443 ;; *) printf 80 ;; esac ;;
  esac
}
# check_link <tid> <node> <repo_id> <ports>: <ports> is the instance's HTTP and HTTPS port, either of which a
# link template may name (the proxy redirects HTTP to HTTPS on the same instance).
check_link() {
  local tid="$1" node="$2" repo="$3" want_port="$4" url port
  url=$(printf '%s' "$X1_RESP" | jq -r --arg n "$node" --arg r "$repo" \
    '[.results[]? | .sourceDocument | select(.nodeId == $n and ((.sourceId // "") | endswith($r)))
       | .openInSourceUrl // empty][0] // empty' 2>/dev/null)
  port=$(port_of "$url")
  if [ -n "$url" ] && [[ " ${want_port} " == *" ${port} "* ]] && [[ "$url" == */aca/* ]] && [[ "$url" == *"$node"* ]]; then
    pass "${tid}: ${repo} document opens in the ACA on port ${port} (${url})"
  else
    fail "${tid}: ${repo} document link '${url}' should be an /aca/ URL on port ${want_port// / or } naming node ${node}"
  fi
}
check_link "K1" "$SALES_A" "$REPO_A" "${PUBLIC_PORT:-80} 443"
check_link "K2" "$SALES_B" "$REPO_B" "${ALFRESCO_2_PUBLIC_PORT:-8082} ${ALFRESCO_2_HTTPS_PORT:-8445}"

# === G: groups per source ============================================================================
section "G Groups per source"
Q_FIN_B="Oslo office finance ledger loan ferry operator ${RUN_TAG}"
Q_SALES_B="Andromeda kettle southern region heron accounts ${RUN_TAG}"
expect_present "G1" "control: ${U_SALES} (Finance in B) sees B's Finance document" \
  "$Q_FIN_B" "$FIN_B" "$REPO_B" -u "${U_SALES}:${PW}"
expect_present "G2" "${U_FIN} (Finance in A only) sees A's Finance document" \
  "Lisbon office finance ledger provision copper futures ${RUN_TAG}" "$FIN_A" "$REPO_A" -u "${U_FIN}:${PW}"
expect_absent "G3" "${U_FIN} does not see B's Finance document (not in ${G_FIN} in B)" \
  "$Q_FIN_B" "$FIN_B" "$REPO_B" -u "${U_FIN}:${PW}"
expect_present "G4" "${U_FIN} (in ${G_SALES} in A) sees A's Sales document" \
  "Andromeda kettle northern region kestrel accounts ${RUN_TAG}" "$SALES_A" "$REPO_A" -u "${U_FIN}:${PW}"
expect_absent "G5" "${U_FIN} does not see B's Sales document (same-named group, not a member in B)" \
  "$Q_SALES_B" "$SALES_B" "$REPO_B" -u "${U_FIN}:${PW}"

# === L: login per source =============================================================================
section "L Login per source"
Q_PUB_A="cafeteria floor nine cardamom buns Fridays notice ${RUN_TAG}"
Q_DUAL_A="Graz tram depot pantograph springs maintenance ${RUN_TAG}"
Q_DUAL_B="Bolzano cable car brake pads maintenance ${RUN_TAG}"
expect_present "L1" "control: ${U_SALES} sees A's public notice" \
  "$Q_PUB_A" "$PUB_A" "$REPO_A" -u "${U_SALES}:${PW}"
expect_present "L2" "${U_BONLY} (B only, same password convention, plain Basic) sees B's document" \
  "Point Varga lighthouse Fresnel lens field report ${RUN_TAG}" "$BONLY_B" "$REPO_B" -u "${U_BONLY}:${PW}"
expect_absent "L3" "${U_BONLY} gets nothing from A, not even a document shared with everyone there" \
  "$Q_PUB_A" "$PUB_A" "$REPO_A" -u "${U_BONLY}:${PW}"

HDR_BOTH="X-Source-Authorization: $(source_header "$REPO_A" "$U_DUAL" "$PW_DUAL_A"), $(source_header "$REPO_B" "$U_DUAL" "$PW_DUAL_B")"
expect_present "L4" "${U_DUAL} with a different password per source (X-Source-Authorization) sees A's document" \
  "$Q_DUAL_A" "$DUAL_A" "$REPO_A" -H "$HDR_BOTH"
expect_present "L5" "${U_DUAL} with X-Source-Authorization sees B's document" \
  "$Q_DUAL_B" "$DUAL_B" "$REPO_B" -H "$HDR_BOTH"
expect_present "L6" "${U_DUAL} with A's password as plain Basic sees A's document" \
  "$Q_DUAL_A" "$DUAL_A" "$REPO_A" -u "${U_DUAL}:${PW_DUAL_A}"
expect_absent "L7" "${U_DUAL} with A's password as plain Basic gets no name in B" \
  "$Q_DUAL_B" "$DUAL_B" "$REPO_B" -u "${U_DUAL}:${PW_DUAL_A}"
expect_code "L8" "a wrong password for B in X-Source-Authorization is rejected" 401 "$Q_DUAL_B" \
  -H "X-Source-Authorization: $(source_header "$REPO_B" "$U_DUAL" "$PW_DUAL_A")"
expect_code "L9" "an unknown source in X-Source-Authorization is rejected" 401 "$Q_DUAL_B" \
  -H "X-Source-Authorization: $(source_header "no-such-repo-${RUN_TAG}" "$U_DUAL" "$PW_DUAL_B")"

# === A: admin bypass =================================================================================
section "A Admin bypass"
if [ "$ADMIN_BYPASS" = "true" ]; then
  Q_ADM_B="Tokaj vineyard sale postponed board minutes ${RUN_TAG}"
  expect_present "A1" "control: ${U_SALES} sees B's board minutes" \
    "$Q_ADM_B" "$ADM_B" "$REPO_B" -u "${U_SALES}:${PW}"
  expect_present "A2" "${U_ADM} (administrator of A) sees A's board minutes without a grant" \
    "Cremona violin workshop acquisition approved board minutes ${RUN_TAG}" "$ADM_A" "$REPO_A" -u "${U_ADM}:${PW}"
  expect_absent "A3" "${U_ADM} (not an administrator of B) does not see B's board minutes" \
    "$Q_ADM_B" "$ADM_B" "$REPO_B" -u "${U_ADM}:${PW}"
else
  skip "A: RAG_SECURITY_ADMIN_BYPASS_ENABLED=${ADMIN_BYPASS}, so rag-service has no bypass to isolate."
  echo "    Run with the bypass on (the deployment default) to cover this case."
fi

# === P: ACL change is not lost =======================================================================
section "P ACL change is not lost"
Q_ACL="audit memo warehouse counted pallets Gdansk Antwerp ${RUN_TAG}"
expect_present_pair "P1" "control: ${U_SALES} sees both audit memos before the change" \
  "$Q_ACL" "$ACL_A" "$REPO_A" "$ACL_B" "$REPO_B" -u "${U_SALES}:${PW}"

# Both changes in parallel. No /api/sync/permissions call: the claim is that the repositories' own ACL
# events (content.lake.permission.sync, one broker per instance) both reach the index.
acl_body=$(acl_json "$U_ACL")
t_start=$(date +%s)
curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$A_AUTH" -X PUT "${A_API}/nodes/${ACL_A}" \
  -H 'Content-Type: application/json' -d "$acl_body" > "${TMP}/acl-A.code" 2>/dev/null &
pid_a=$!
curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$B_AUTH" -X PUT "${B_API}/nodes/${ACL_B}" \
  -H 'Content-Type: application/json' -d "$acl_body" > "${TMP}/acl-B.code" 2>/dev/null &
pid_b=$!
wait "$pid_a" "$pid_b"
t_span=$(( $(date +%s) - t_start ))
code_a=$(cat "${TMP}/acl-A.code" 2>/dev/null); code_b=$(cat "${TMP}/acl-B.code" 2>/dev/null)
if [ "$code_a" = "200" ] && [ "$code_b" = "200" ] && [ "$t_span" -le 1 ]; then
  pass "P2: both audit memos re-granted to ${U_ACL} within ${t_span}s"
else
  fail "P2: ACL change answered A=${code_a} B=${code_b} over ${t_span}s (expected 200, 200 within 1s)"
fi
# Longer than POLL_DEADLINE_S, by measurement: each batch ingester has one ACL queue consumer, and a
# folder-level ACL message holds it for up to 30 s (10 descendant-discovery attempts 3 s apart while the
# repository's search index catches up). The seeding above queues several folder messages ahead of these.
saved_deadline="$POLL_DEADLINE_S"; POLL_DEADLINE_S="$ACL_DEADLINE_S"
expect_present_pair "P3" "${U_ACL} sees both audit memos: both ACL changes reached the index" \
  "$Q_ACL" "$ACL_A" "$REPO_A" "$ACL_B" "$REPO_B" -u "${U_ACL}:${PW}"
p3_status=$?
POLL_DEADLINE_S="$saved_deadline"
if [ "$p3_status" = "0" ]; then
  expect_absent "P4" "${U_SALES} no longer sees A's audit memo" \
    "$Q_ACL" "$ACL_A" "$REPO_A" -u "${U_SALES}:${PW}"
  expect_absent "P5" "${U_SALES} no longer sees B's audit memo" \
    "$Q_ACL" "$ACL_B" "$REPO_B" -u "${U_SALES}:${PW}"
else
  echo "    The ACL change travels as a JMS event from each repository to its batch ingester. Check the"
  echo "    batch-ingester and batch-ingester-2 logs for the acl.changed listener."
fi

# === D: deletion isolation ===========================================================================
section "D Deletion isolation"
Q_DEL_A="Ghent branch invoices retention policy eleven years ${RUN_TAG}"
Q_DEL_B="Porto branch invoices retention policy seven years ${RUN_TAG}"
expect_present_pair "D1" "both ${DEL_NAME} documents are retrievable before the delete" \
  "retention policy invoices branch kept years Ghent Porto ${RUN_TAG}" \
  "$DEL_A" "$REPO_A" "$DEL_B" "$REPO_B" -u "${U_SALES}:${PW}"

code=$(alf_req B DELETE "/nodes/${DEL_B}?permanent=true")
if [ "$code" = "204" ]; then
  pass "D2: ${DEL_NAME} deleted in B (HTTP 204)"
else
  fail "D2: deleting ${DEL_NAME} in B answered HTTP ${code}"
fi

# Waiting here is for a change to arrive (live-ingester-2's delete event), not to conclude an absence:
# D1 proved the document was retrievable a moment ago.
waited=0; gone=0
while :; do
  rag_search "$Q_DEL_B" -u "${U_SALES}:${PW}"
  if [ "$RESP_CODE" = "200" ] && ! hit "$DEL_B" "$REPO_B"; then gone=1; break; fi
  [ "$waited" -ge "$POLL_DEADLINE_S" ] && break
  sleep 5; waited=$((waited+5))
done
if [ "$gone" = "1" ]; then
  pass "D3: B's ${DEL_NAME} left the index (after ${waited}s)"
else
  fail "D3: B's ${DEL_NAME} is still retrievable ${waited}s after the delete (live-ingester-2 delete event)"
  show_top
fi
expect_present "D4" "A's ${DEL_NAME} stays after the delete in B" \
  "$Q_DEL_A" "$DEL_A" "$REPO_A" -u "${U_SALES}:${PW}"

# A reconciling sync on B: its sweep deletes what B's discovery no longer sees, and must not reach A's
# document of the same name.
wait_afts B "$B_FOLDER" $((PER_REPO - 1))
start_sync B "$B_FOLDER" JOB_D
if [ -n "$JOB_D" ] && wait_sync B "$JOB_D"; then
  pass "D5: reconciling sync on B COMPLETED (reconciliation: $(jq -c '.reconciliation // {}' "$BODY" 2>/dev/null))"
else
  fail "D5: reconciling sync on B did not complete: $(jq -c . "$BODY" 2>/dev/null | head -c 300)"
fi
expect_present "D6" "A's ${DEL_NAME} stays after B's reconciliation" \
  "$Q_DEL_A" "$DEL_A" "$REPO_A" -u "${U_SALES}:${PW}"
expect_absent "D7" "B's ${DEL_NAME} is still gone after B's reconciliation" \
  "$Q_DEL_B" "$DEL_B" "$REPO_B" -u "${U_SALES}:${PW}"

# === Summary =========================================================================================
summary
[ "$FAIL" -eq 0 ]
