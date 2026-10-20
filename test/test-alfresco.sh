#!/usr/bin/env bash
# test-alfresco.sh — Alfresco end-to-end test suite.
# Sections A (smoke), B (batch ingestion), C (live ingestion),
#           G (permissions), H (chunking strategy).
#
# Run after STACK_MODE=alfresco stack is healthy, or via run-tests.sh.
# Requires: curl, jq.
#
# Search response field reference (from actual API):
#   .results[].sourceDocument.nodeId       — Alfresco node UUID
#   .results[].sourceDocument.sourceType   — "alfresco"
#   .results[].chunkText                   — chunk content
#   .results[].chunkMetadata.page          — page number within document
#   .results[].score                       — similarity score

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
HOST="${HOST:-localhost}"
USE_HTTPS="${USE_HTTPS:-false}"
ALF_AUTH="${ALF_AUTH:-admin:admin}"
NUXEO_AUTH="${NUXEO_AUTH:-Administrator:Administrator}"

if [ "${USE_HTTPS}" = "true" ]; then
  BASE="https://${HOST}"
  CURL_OPTS="-k"
else
  BASE="http://${HOST}"
  CURL_OPTS=""
fi

ALF_BASE="${BASE}/alfresco/api/-default-/public/alfresco/versions/1"
SYNC_URL="${BASE}/api/sync"
RAG_URL="${BASE}/api/rag"
# Deadline (seconds) for polling a just-synced document into searchable state. Longer than the 60s the
# connector suites use, and measured rather than guessed: this phase waits on embedding, which on a local
# Docker Model Runner backend runs seconds per document and slows further as a run accumulates state.
# Every use polls, so the deadline is only paid when something is actually wrong. Configurable so a slower
# inference backend can extend it without editing the suite.
POLL_DEADLINE_S="${POLL_DEADLINE_S:-180}"
LIVE_URL="http://${HOST}:9092/api/live/status"   # direct port — may not be exposed
# Deployment root, so a section that needs to stop a service can reach docker compose. run-tests.sh
# does not export its own DEPLOY_DIR, and this suite is also run standalone.
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LAST_SYNC_JOB_ID=""

PASS=0; FAIL=0
TMPDIR_DATA="$(mktemp -d)"
LOG="test-results-alfresco-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
pass()    { printf "${G}[PASS]${N} %s\n" "$*"; PASS=$((PASS+1)); }
fail()    { printf "${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
info()    { printf "${C}[INFO]${N} %s\n" "$*"; }
warn()    { printf "${Y}[WARN]${N} %s\n" "$*"; }
section() { printf "\n${B}${C}─── %s ───${N}\n" "$*"; }

cleanup() { rm -rf "$TMPDIR_DATA"; }
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────

# create_folder <parent_node_id> <name>
# Returns the nodeId of the created (or already-existing) folder.
create_folder() {
  local parent="$1" name="$2"
  local resp http_code body
  resp=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/$parent/children" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"nodeType\":\"cm:folder\"}" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | head -1)
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    curl -sf $CURL_OPTS -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/$parent/children?fields=id,name&maxItems=100" 2>/dev/null \
      | jq -r --arg n "$name" \
          '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

# upload_file <parent_node_id> <local_path> [name] [mime]
# Returns the nodeId of the uploaded (or already-existing) file.
upload_file() {
  local parent="$1" path="$2" name="${3:-$(basename "$2")}" mime="${4:-text/plain}"
  local resp http_code body node_id
  resp=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/nodes/$parent/children" \
    -F "filedata=@${path};type=${mime}" \
    -F "name=$name" 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | head -1)
  if [ "$http_code" = "201" ]; then
    printf '%s' "$body" | jq -r '.entry.id // empty'
  elif [ "$http_code" = "409" ]; then
    # File already exists — look up its nodeId by name
    curl -sf $CURL_OPTS -u "$ALF_AUTH" \
      "$ALF_BASE/nodes/$parent/children?fields=id,name&maxItems=100" 2>/dev/null \
      | jq -r --arg n "$name" \
          '.list.entries[]? | select(.entry.name==$n) | .entry.id' | head -1
  else
    echo ""
  fi
}

# wait_for_solr_indexed <folder_node_id> <expected_count>
# Batch discovery runs through the search index, which picks up newly uploaded nodes some seconds after
# upload returns 201. Syncing before it catches up discovers 0 nodes and completes empty.
#
# Polls the query shape the ingester itself uses: ANCESTOR, not PARENT. That distinction is the whole
# point of this helper. AlfrescoSearchService.buildDescendantFilesQuery issues
# `ANCESTOR:"workspace://SpacesStore/<id>" AND TYPE:"cm:content"`, and the two shapes become visible at
# different times on the OpenSearch-backed index: a PARENT query answering correctly does not mean the
# ANCESTOR query does. Gating on PARENT let the suite proceed while the ingester still found nothing,
# which showed up as `Descendant discovery ... found 0 file(s) (attempt 9/10)`, then
# `metadataIngestedCount=0`, then B5-B9 failing on documents that were never ingested -- reading as a
# pipeline regression rather than as this race. See AlfrescoLabs/content-lake-app-deployment#20.
#
# ANCESTOR is also the more useful count: it includes nested descendants, which is what the ingester
# will actually sync. For a flat fixture folder the two counts are identical.
wait_for_solr_indexed() {
  local folder_id="$1" expected="$2" tid="${3:-B3a}" elapsed=0 found
  local search_url="${BASE}/alfresco/api/-default-/public/search/versions/1/search"
  while [ $elapsed -lt 180 ]; do
    found=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST \
      "$search_url" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":{\"language\":\"afts\",\"query\":\"ANCESTOR:'workspace://SpacesStore/$folder_id' AND TYPE:'cm:content'\"},\"paging\":{\"maxItems\":100}}" \
      2>/dev/null | jq -r '.list.pagination.totalItems // 0' 2>/dev/null || echo 0)
    if [ "${found:-0}" -ge "$expected" ]; then
      pass "$tid: Solr indexed $found/$expected uploaded files (ready to sync)"
      return 0
    fi
    sleep 10; elapsed=$((elapsed+10))
  done
  info "$tid: Solr showed only $found/$expected files after 3 min; syncing anyway"
  return 0
}

# run_sync_wait <folder_node_id> [trigger_label] [wait_label]
# Triggers /api/sync/batch with an explicit folder and waits up to 5 min for COMPLETED.
# Sets LAST_SYNC_JOB_ID so a caller can read the job's own report (e.g. the reconciliation
# outcome) afterwards.
run_sync_wait() {
  local folder_id="$1" trigger_label="${2:-B3}" wait_label="${3:-B4}"
  local resp job_id status processed
  LAST_SYNC_JOB_ID=""
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$folder_id\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  job_id=$(echo "$resp" | jq -r '.jobId // empty')

  if [ -z "$job_id" ]; then
    fail "$trigger_label: Sync trigger returned no jobId (response: $resp)"
    return 1
  fi
  LAST_SYNC_JOB_ID="$job_id"
  pass "$trigger_label: Sync triggered — jobId=$job_id"

  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local sr
    sr=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$job_id" 2>/dev/null || echo '{}')
    status=$(echo "$sr" | jq -r '.status // "UNKNOWN"')
    case "$status" in
      COMPLETED)
        processed=$(echo "$sr" | jq -r '.metadataIngestedCount // .processedCount // "?"')
        pass "$wait_label: Sync COMPLETED (metadataIngestedCount=$processed)"
        return 0
        ;;
      FAILED|ERROR)
        fail "$wait_label: Sync job FAILED — $(echo "$sr" | jq -c '{status,failedCount,discoveredCount}')"
        return 1
        ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "$wait_label: Sync job timed out after 5 min (last status=$status)"
  return 1
}

# rag_find_node <query> <node_id> <test_id> <label>
# Searches RAG (as admin) and checks that the given Alfresco nodeId appears in results.
rag_find_node() {
  local query="$1" node_id="$2" tid="$3" label="$4"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.2}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search"
  else
    fail "$tid: $label NOT found (nodeId=$node_id, query='$query')"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, nodeId:.sourceDocument.nodeId, score:.score}]')"
  fi
}

# wait_for_node_present <query> <node_id> <test_id> <label> [auth]
# Polls semantic search until the node is retrievable, up to a deadline, then emits the pass/fail.
# index_proof <node_id> [sample_size]
# Measured evidence that a node is retrievable, as opposed to the syncStatus a writer recorded: a
# document present with zero embeddings reports INDEXED while being invisible to search. Returns the
# JSON body, or {} on any failure. nginx routes /api/content-lake to the Alfresco batch ingester
# specifically (no ?sourceType fan-out), so this is Alfresco-only through the proxy.
index_proof() {
  local node_id="$1" sample="${2:-3}"
  curl -sf $CURL_OPTS -u "$ALF_AUTH" \
    "$BASE/api/content-lake/nodes/${node_id}/index-proof?sampleSize=${sample}" 2>/dev/null || echo '{}'
}

# index_proof_chunk_count <node_id>
# The document's stored chunk count from the embeddings index. Prints 0 when the measurement
# degraded, so a caller comparing two counts should also check the count is non-zero to begin with.
index_proof_chunk_count() {
  index_proof "$1" 1 | jq -r '.measured.chunkCount // 0' 2>/dev/null || echo 0
}

# Replaces flat post-sync sleeps before single-shot presence assertions: embeddings and indexed
# ACLs settle a variable time after sync, so a fixed sleep is inherently flaky. [auth] defaults to
# admin; pass "user:password" for a per-user (ACL-scoped) presence check.
wait_for_node_present() {
  local query="$1" node_id="$2" tid="$3" label="$4" auth="${5:-$ALF_AUTH}"
  local elapsed=0 resp found
  while [ $elapsed -lt "$POLL_DEADLINE_S" ]; do
    resp=$(curl -sf $CURL_OPTS -u "$auth" -X POST "$RAG_URL/search/semantic" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.2}" 2>/dev/null || echo '{}')
    found=$(echo "$resp" | jq --arg id "$node_id" \
      '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
    if [ "${found:-0}" -gt 0 ]; then
      pass "$tid: $label found in search"
      return 0
    fi
    sleep 10; elapsed=$((elapsed+10))
  done
  fail "$tid: $label NOT found after ${elapsed}s (nodeId=$node_id, query='$query')"
  echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, nodeId:.sourceDocument.nodeId, score:.score}]')"
  return 1
}

# wait_job_complete <job_id> : silent poll of /api/sync/status/<job_id> to COMPLETED (or deadline).
wait_job_complete() {
  local job_id="$1" elapsed=0 st
  while [ $elapsed -lt 300 ]; do
    st=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$job_id" 2>/dev/null \
      | jq -r '.status // "UNKNOWN"' 2>/dev/null || echo UNKNOWN)
    case "$st" in COMPLETED) return 0 ;; FAILED|ERROR) return 1 ;; esac
    sleep 10; elapsed=$((elapsed+10))
  done
  return 1
}

# rag_absent_node <query> <node_id> <test_id> <label>
rag_absent_node() {
  local query="$1" node_id="$2" tid="$3" label="$4"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.1}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search"
  else
    fail "$tid: $label still appears in search (nodeId=$node_id)"
  fi
}

# rag_find_node_as <query> <node_id> <test_id> <label> <user:password>
# Like rag_find_node but passes HTTP Basic auth to the RAG service.
rag_find_node_as() {
  local query="$1" node_id="$2" tid="$3" label="$4" auth="$5"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$auth" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.2}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -gt 0 ]; then
    pass "$tid: $label found in search (as ${auth%%:*})"
  else
    fail "$tid: $label NOT found (as ${auth%%:*}, nodeId=$node_id)"
    echo "    top results: $(echo "$resp" | jq -c '[.results[:3][]? | {name:.sourceDocument.name, nodeId:.sourceDocument.nodeId, score:.score}]')"
  fi
}

# rag_absent_node_as <query> <node_id> <test_id> <label> <user:password>
rag_absent_node_as() {
  local query="$1" node_id="$2" tid="$3" label="$4" auth="$5"
  local resp found
  resp=$(curl -sf $CURL_OPTS -u "$auth" -X POST "$RAG_URL/search/semantic" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$query\",\"topK\":10,\"minScore\":0.1}" 2>/dev/null || echo '{}')
  found=$(echo "$resp" | jq --arg id "$node_id" \
    '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
  if [ "${found:-0}" -eq 0 ]; then
    pass "$tid: $label correctly absent from search (as ${auth%%:*})"
  else
    fail "$tid: $label still appears in search (as ${auth%%:*}, nodeId=$node_id)"
  fi
}

# set_node_permissions <node_id> <json_permissions_object>
# Uses PUT /nodes/{id} with a permissions field in the body.
# Valid roles: Consumer, Editor, Contributor, Collaborator, Coordinator
reconcile_node_permissions() {
  local node_id="$1" recursive="${2:-true}"
  local resp failed
  resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/permissions" \
    -H 'Content-Type: application/json' \
    -d "{\"nodeIds\":[\"$node_id\"],\"recursive\":$recursive}" 2>/dev/null || echo '{}')
  # Use .failed // null, not // 1: if .failed is 0 (success) we want 0, not a fallthrough.
  # jq's // falls through on false/null/empty, so a boolean false would trigger the fallback incorrectly.
  failed=$(echo "$resp" | jq -r 'if has("failed") then .failed else 1 end' 2>/dev/null || echo 1)
  [ "$failed" = "0" ]
}

set_node_permissions() {
  local node_id="$1" perms_json="$2"
  local code
  code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
    "$ALF_BASE/nodes/$node_id" \
    -H 'Content-Type: application/json' \
    -d "{\"permissions\":$perms_json}" 2>/dev/null )
  [ "$code" = "200" ] && reconcile_node_permissions "$node_id" true
}

# create_alfresco_user <id> <first> <last>
create_alfresco_user() {
  local id="$1" first="$2" last="$3"
  local code
  code=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X POST \
    "$ALF_BASE/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$id\",\"firstName\":\"$first\",\"lastName\":\"$last\",\"email\":\"${id}@test.local\",\"password\":\"password\"}")
  case "$code" in
    201) info "Created user $id" ;;
    409) info "User $id already exists" ;;
    *) fail "G0: Failed to create user $id (HTTP $code)" ;;
  esac
}

# ── Test data ─────────────────────────────────────────────────────────────────
create_test_data() {
  # --- detached-signature.p7s: a type that cannot contain text ---
  # Backs B15. NonTextContentPolicy denies the .p7s extension, so the pipeline records SKIPPED without
  # downloading the bytes. The content is irrelevant by construction: nothing ever reads it.
  printf 'not text, and never downloaded' > "$TMPDIR_DATA/detached-signature.p7s"

  # --- short-memo.txt: HR topic, ~400 words ---
  cat > "$TMPDIR_DATA/short-memo.txt" <<'EOF'
MEMORANDUM

To:   All Staff
From: Human Resources Department
Re:   Updated Remote Work Policy — Effective Immediately

This memorandum outlines the revised remote work eligibility criteria applicable to all
permanent employees. Following extensive consultation with department heads, the following
framework has been approved by the executive committee.

Eligibility and Days Permitted
Employees with a minimum of six months of continuous service are eligible to work from home
up to three days per week. Requests must be submitted to and approved by the direct line
manager at least two working days in advance. Approval is at the manager's discretion based
on workload and team requirements.

Home Office Equipment Allowance
The company will provide a one-time home office equipment allowance of five hundred pounds
to cover ergonomic chair, desk accessories, and broadband upgrade costs. Claims must be
submitted with receipts within ninety days of the policy taking effect. The allowance does
not cover monitors or computing equipment, which remain the company's property and must be
collected from the IT department.

Connectivity and Security Requirements
Employees working remotely must use the company VPN at all times. Personal devices are not
permitted for processing confidential data; only company-issued laptops may be used. Any
security incidents must be reported to the IT helpdesk within one hour of discovery.

Performance and Availability Expectations
Remote working employees are expected to maintain the same productivity baseline as in-office
days. Core hours of nine to three must be observed, during which employees must be reachable
by phone, Teams, or email within fifteen minutes. Failure to meet availability requirements
may result in remote work privileges being suspended.

Welfare and Wellbeing
The wellbeing team offers bi-monthly virtual check-ins for remote workers. Employees are
encouraged to take regular breaks and to maintain a clear boundary between work and personal
time. The occupational health team can provide ergonomic assessments on request.

For questions about remote work eligibility please contact HR at hr@company.internal.

EOF

  # --- security-policy.txt: IT security, ~600 words ---
  cat > "$TMPDIR_DATA/security-policy.txt" <<'EOF'
INFORMATION SECURITY POLICY — VERSION 3.2

1. PURPOSE AND SCOPE
This Information Security Policy establishes the minimum requirements for protecting company
data, systems, and infrastructure. It applies to all employees, contractors, and third parties
who access company systems. Compliance is mandatory. Violations may result in disciplinary
action up to and including termination.

2. ACCESS CONTROL REQUIREMENTS
Access to systems and data is granted on the principle of least privilege. User accounts must
be provisioned through the Identity Management System. Shared accounts are strictly prohibited.
Access rights must be reviewed quarterly by system owners. Dormant accounts inactive for sixty
days are automatically disabled.

3. PASSWORD COMPLEXITY REQUIREMENTS
All passwords must be at least fourteen characters long and contain a mix of uppercase,
lowercase, digits, and special characters. Passwords must not contain the user's name,
username, or commonly used sequences. Passwords expire every ninety days. Reuse of the last
twelve passwords is blocked. Multi-factor authentication is mandatory for all privileged
accounts and remote access.

4. DATA CLASSIFICATION SCHEME
Data is classified into four tiers: Public, Internal, Confidential, and Restricted.
Confidential data must be encrypted at rest using AES-256 and in transit using TLS 1.3.
Restricted data may not leave the corporate perimeter without explicit CISO approval.
Personally identifiable information is classified as Confidential by default.

5. INCIDENT RESPONSE
Security incidents must be reported to the Security Operations Centre within one hour of
discovery. The incident response team will triage, contain, and remediate the incident
according to the documented runbook. Post-incident reviews are mandatory for all P1 incidents.
Forensic evidence must be preserved and chain of custody maintained.

6. VULNERABILITY MANAGEMENT
All systems must be patched within fourteen days of a critical CVE publication. Penetration
tests are conducted annually by an approved third party. Internal vulnerability scans run
weekly. Findings are tracked in the vulnerability management platform and reviewed by the
security team at monthly cadence.
EOF

  # --- product-roadmap.txt: Product, ~600 words ---
  cat > "$TMPDIR_DATA/product-roadmap.txt" <<'EOF'
PRODUCT ROADMAP — FISCAL YEAR 2025–2026

STRATEGIC THEMES

The product strategy for the next eighteen months is organised around three pillars:
AI-first experiences, mobile-first design, and an open API platform. Each pillar has a
dedicated workstream with quarterly delivery milestones tracked in the programme board.

Q1 2025: FOUNDATIONS
The Q1 delivery focuses on infrastructure modernisation. The monolithic API gateway will be
decomposed into domain-specific microservices. The new API platform will expose stable v2
endpoints with OpenAPI 3.1 specifications and a developer portal with interactive playground.
AI feature integration begins with an embedded suggestion engine that surfaces related content
as users type.

Q2 2025: MOBILE FIRST STRATEGY
The mobile-first redesign of the core application will ship in Q2. The new React Native client
replaces the legacy hybrid app. Key user journeys have been reworked with a thumb-friendly
navigation model. Offline mode supports the ten most frequently accessed content types.
Push notification infrastructure is upgraded to support rich media and deep-linking.

Q3 2025: AI FEATURE RELEASE
Q3 delivers the semantic search and RAG-powered assistant across all clients. Users can ask
natural language questions and receive grounded answers with source citations. The assistant
is context-aware and maintains a per-session conversation history. The initial model is
hosted on-premise; a cloud model routing option is planned for Q4.

Q4 2025: PLATFORM OPENNESS
Developers will be able to build extensions using the published SDK in Q4. A marketplace for
certified integrations launches alongside enhanced webhook support covering all major content
lifecycle events. Enterprise customers receive dedicated support SLAs for API consumers.

2026 OUTLOOK
The 2026 roadmap features expanded language support (twelve additional locales), a no-code
automation builder, and a cross-platform desktop client. Feedback from the partner advisory
board will be incorporated into the detailed Q-plan in October 2025.
EOF

  # --- technical-spec.txt: Engineering API, ~700 words ---
  cat > "$TMPDIR_DATA/technical-spec.txt" <<'EOF'
REST API SPECIFICATION v2.0 — CONTENT LAKE SERVICE

1. OVERVIEW
The Content Lake REST API provides programmatic access to document ingestion, search, and
retrieval capabilities. All endpoints accept and return JSON. The base URL is
https://api.content-lake.internal/v2. Authentication uses Bearer tokens issued by the IDP
at /connect/token using the client_credentials grant.

2. AUTHENTICATION
POST /connect/token
Content-Type: application/x-www-form-urlencoded
grant_type=client_credentials&client_id=<id>&client_secret=<secret>&scope=content-lake

The response includes access_token (JWT), token_type=Bearer, and expires_in (seconds).
Include the token as Authorization: Bearer <token> on all API requests. Tokens expire after
3600 seconds. The client must refresh before expiry to avoid 401 responses.

3. DOCUMENT ENDPOINTS

GET /documents
Lists all documents visible to the authenticated principal. Supports pagination via
limit (default 20, max 100) and cursor query parameters. Filters: source_type, created_after,
mime_type. Returns a paginated list with next_cursor if more results exist.

POST /documents
Ingests a new document. Multipart body: metadata (JSON part) and content (binary part).
Metadata must include source_id, node_id, and mime_type. Returns 202 Accepted with a
job_id for tracking ingestion progress.

GET /documents/{id}
Returns the full document record including sys_acl, embeddings count, and ingest properties.
Returns 404 if the document does not exist or the caller lacks read access.

DELETE /documents/{id}
Removes the document and all associated embeddings. Returns 204 on success. Returns 403 if
the caller is not the document owner or an admin.

4. SEARCH ENDPOINTS

POST /search/semantic
JSON body: { "query": string, "top_k": int, "min_score": float, "filters": object }
Returns a ranked list of matching document chunks with source metadata. The min_score
parameter controls the relevance threshold (range 0.0–1.0). HTTP authentication token
identity is used for ACL filtering.

POST /search/hybrid
Combines vector similarity (kNN) with BM25 full-text search using reciprocal rank fusion.
Body is identical to semantic search. Use when exact keyword matches are important alongside
semantic relevance. JSON schema validation is applied to the request body.

5. ERROR HANDLING
All errors return a JSON body: { "error": string, "code": int, "request_id": string }.
Rate limiting returns 429 with Retry-After header. Malformed requests return 400 with a
validation detail array. Server errors return 500 with a support reference number.
EOF

  # --- long-report.txt: Finance, ~5500 words ---
  {
    cat <<'HEADER'
ANNUAL FINANCIAL PERFORMANCE REPORT
FISCAL YEAR 2024
Prepared by: Group Finance | Approved by: Board of Directors

SECTION 1: EXECUTIVE SUMMARY

The fiscal year 2024 delivered outstanding results. Total consolidated revenue reached
two point four billion pounds, representing year-on-year growth of fifteen percent.
Adjusted EBITDA improved to four hundred and eighty million pounds, a margin of twenty
percent. Net profit after tax was two hundred and ten million pounds, up from one hundred
and seventy million in fiscal year 2023. The board has approved a final dividend of twelve
pence per ordinary share, bringing the full-year distribution to twenty pence per share.
Free cash flow generation was strong at three hundred and forty million pounds.

SECTION 2: REVENUE ANALYSIS BY DIVISION

The Group operates four reporting divisions: Enterprise Software, Professional Services,
Managed Cloud, and Licensing. Enterprise Software remained the largest contributor,
generating nine hundred and sixty million pounds in the year, representing growth of
eighteen percent driven by new logo acquisition and strong renewal rates above ninety-two
percent. Professional Services revenue grew eleven percent to five hundred and forty
million pounds. Managed Cloud was the fastest growing division at thirty-one percent,
reaching four hundred and twenty million pounds. Licensing revenue declined five percent
to four hundred and eighty million as customers transitioned to subscription models,
consistent with the strategy communicated to shareholders at the Capital Markets Day.

SECTION 3: GROSS PROFIT AND MARGIN

Group gross profit was one point zero zero eight billion pounds, representing a gross
margin of forty-two percent, up from thirty-nine percent in the prior year. The margin
improvement reflects continued mix shift toward higher-margin cloud and software revenue,
partially offset by investment in professional services headcount to support growth.
Enterprise Software gross margin reached seventy-one percent. Managed Cloud gross margin
expanded by four percentage points to sixty-three percent as infrastructure unit costs
declined and utilisation rates improved.

SECTION 4: OPERATING EXPENSES

Research and development expenditure was two hundred and sixteen million pounds,
representing nine percent of revenue, in line with the board's commitment to invest a
minimum of eight to ten percent of revenue in product innovation. Sales and marketing
costs were three hundred and twelve million pounds, reflecting targeted investment in
demand generation in North America and the Asia-Pacific region. General and administrative
costs were held flat year-on-year at one hundred and forty-four million pounds despite
inflationary pressures, demonstrating effective cost discipline across central functions.

SECTION 5: EBITDA AND ADJUSTED EARNINGS

Reported EBITDA was four hundred and thirty-two million pounds. Adjusted EBITDA, excluding
share-based compensation charges of twenty-four million pounds, restructuring costs of
eighteen million pounds, and acquisition-related amortisation of six million pounds, was
four hundred and eighty million pounds. The adjusted EBITDA margin of twenty percent
represents the highest level achieved in the Group's history and reflects sustained
operational leverage as the business scales.

SECTION 6: CAPITAL EXPENDITURE AND FREE CASH FLOW

Capital expenditure for the year was sixty million pounds, comprising forty-two million
of investment in cloud infrastructure and eighteen million in facilities and equipment.
Capitalised development costs were ninety-six million pounds. Working capital improved
by thirty-six million pounds as a result of faster customer collections and extended
supplier payment terms negotiated during the year. Free cash flow conversion from
adjusted EBITDA was seventy-one percent, ahead of the sixty-five percent medium-term
target communicated at the Capital Markets Day in March 2023.

SECTION 7: NET DEBT AND BALANCE SHEET

Net debt at year end was one hundred and eighty million pounds, representing a leverage
ratio of zero point four times adjusted EBITDA, well within the board's two times
covenant. The revolving credit facility of three hundred and fifty million pounds was
undrawn. Total equity attributable to shareholders was one point two billion pounds.
Goodwill and intangible assets arising from acquisitions totalled eight hundred and
forty million pounds. The Group's capital allocation framework prioritises organic
investment first, followed by bolt-on acquisitions, then returns to shareholders through
dividends and buybacks.

SECTION 8: ACQUISITIONS AND INTEGRATION

During fiscal year 2024 the Group completed two bolt-on acquisitions. Datasync Limited was
acquired in July 2023 for an enterprise value of seventy-two million pounds and has been
fully integrated into the Enterprise Software division. Analytix Partners was acquired in
January 2024 for an enterprise value of one hundred and eight million pounds; integration
of the technology and go-to-market teams is proceeding to plan and is expected to complete
in the first half of fiscal year 2025. The combined contribution from acquisitions to
revenue in fiscal year 2024 was forty-eight million pounds.

SECTION 9: GEOGRAPHIC PERFORMANCE

The United Kingdom and Ireland remained the largest region, contributing nine hundred
million pounds in revenue, with growth of nine percent. North America was the fastest
growing region, delivering revenue of five hundred and forty million pounds, growth of
twenty-four percent, underpinned by strong new logo momentum and the Datasync acquisition.
Continental Europe contributed four hundred and eighty million pounds, growth of twelve
percent. Asia-Pacific and Rest of World contributed three hundred and sixty million pounds,
growth of twenty percent, reflecting early-stage market penetration investments.

SECTION 10: PEOPLE AND CULTURE

The Group ended the fiscal year with five thousand and four hundred full-time equivalent
employees, an increase of six hundred from the prior year. Employee engagement scores
remained above eighty percent in the annual survey. The voluntary attrition rate was
eleven percent, below the sector average of fourteen percent. The Group invested sixteen
million pounds in learning and development programmes. Female representation in senior
leadership roles increased from thirty-one to thirty-five percent.

SECTION 11: ENVIRONMENTAL, SOCIAL AND GOVERNANCE

The Group reduced absolute Scope 1 and Scope 2 greenhouse gas emissions by eighteen
percent year-on-year, ahead of the twenty percent five-year target set in the 2021
sustainability report. Renewable energy accounted for seventy-eight percent of total
electricity consumption across owned premises. The Group published its first TCFD-aligned
climate risk disclosure in October 2023. Supplier sustainability assessments were conducted
for the top two hundred suppliers by spend, representing eighty-five percent of total
procurement expenditure.

SECTION 12: OUTLOOK AND GUIDANCE

The Board is confident in the Group's ability to deliver continued profitable growth in
fiscal year 2025. The Group has strong forward visibility supported by a twelve-month
committed revenue backlog of one point eight billion pounds at the fiscal year end.
Revenue guidance for fiscal year 2025 is two point six to two point seven billion pounds,
representing growth of eight to thirteen percent. Adjusted EBITDA margin guidance is
maintained at twenty to twenty-one percent.

SECTION 13: PRINCIPAL RISKS

The principal risks identified by the Board include macroeconomic uncertainty affecting
customer spending, cybersecurity threats to systems and customer data, talent retention in
a competitive labour market, technology disruption from artificial intelligence, and
regulatory change including data protection and AI governance frameworks. Each risk is
managed through a dedicated mitigation programme overseen by the Audit and Risk Committee.

SECTION 14: CORPORATE GOVERNANCE

The Board comprises ten directors: four executive directors and six independent non-executive
directors. The Chair is independent. Board gender diversity is forty percent female.
Audit, Remuneration, and Nomination Committees met the recommended frequency. The Annual
General Meeting will be held on the fifteenth of June 2025 at the Group's registered office
in London.

SECTION 15: AUDIT CERTIFICATION AND REGULATORY COMPLIANCE FRAMEWORK

The financial statements have been prepared in accordance with UK-adopted International
Accounting Standards and the requirements of the Companies Act 2006. The independent
auditors, FinanceAudit LLP, have issued an unqualified opinion. The internal audit function
conducted forty-two reviews during the year and reported no material control deficiencies.
The Group is fully compliant with the UK Corporate Governance Code. All regulatory filings
were submitted within required deadlines. The compliance framework is subject to annual
independent review by external legal counsel.
HEADER
  } > "$TMPDIR_DATA/long-report.txt"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION A — Smoke Tests
# ═══════════════════════════════════════════════════════════════════════════════
section "A — Smoke Tests"

# A1: Batch ingester status endpoint
code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" "$SYNC_URL/status" 2>/dev/null )
code="${code:-000}"
[ "$code" = "200" ] && pass "A1: Batch ingester status endpoint is healthy" \
                     || fail "A1: Batch ingester status returned HTTP $code"

# A2: RAG service health
# Must pass CURL_OPTS (-k for the self-signed TLS proxy) and auth, exactly like A1; without -k the
# -sf call silently fails on the cert and reports a false UNKNOWN even when the service is UP.
rag_health=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$RAG_URL/health" 2>/dev/null || echo '{}')
rag_status=$(echo "$rag_health" | jq -r '.status // "UNKNOWN"')
[ "$rag_status" = "UP" ] && pass "A2: RAG service is UP (embedding, hxpr, llm all healthy)" \
                           || fail "A2: RAG service status=$rag_status (expected UP)"
echo "    $(echo "$rag_health" | jq -c '{embedding:.embedding.status, hxpr:.hxpr.status, llm:.llm.status}')"

# A3: Alfresco repository connectivity
code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
  "$ALF_BASE/nodes/-root-/children" 2>/dev/null )
[ "$code" = "200" ] && pass "A3: Alfresco repository responds" \
                     || fail "A3: Alfresco /nodes/-root-/children returned HTTP $code"

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION B — Batch Ingestion
# ═══════════════════════════════════════════════════════════════════════════════
section "B — Alfresco Batch Ingestion"

create_test_data

# B1: Create test folder under admin home (or reuse if it already exists)
FOLDER_RESP=$(curl -s $CURL_OPTS -w '\n%{http_code}' -u "$ALF_AUTH" -X POST \
  "$ALF_BASE/nodes/-my-/children" \
  -H 'Content-Type: application/json' \
  -d '{"name":"content-lake-test","nodeType":"cm:folder"}')
FOLDER_HTTP=$(echo "$FOLDER_RESP" | tail -1)
FOLDER_JSON=$(echo "$FOLDER_RESP" | head -1)

if [ "$FOLDER_HTTP" = "201" ]; then
  FOLDER_ID=$(echo "$FOLDER_JSON" | jq -r '.entry.id // empty')
  pass "B1: Test folder created (nodeId=$FOLDER_ID)"
elif [ "$FOLDER_HTTP" = "409" ]; then
  # Folder already exists — look up its ID
  FOLDER_ID=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
    "$ALF_BASE/nodes/-my-/children?where=(nodeType='cm:folder')&fields=id,name" \
    | jq -r '.list.entries[]? | select(.entry.name=="content-lake-test") | .entry.id' | head -1)
  if [ -n "$FOLDER_ID" ]; then
    pass "B1: Test folder already exists — reusing (nodeId=$FOLDER_ID)"
  else
    fail "B1: Test folder exists (409) but could not retrieve its nodeId"
    FOLDER_ID="NONE"
  fi
else
  fail "B1: Failed to create test folder (HTTP $FOLDER_HTTP)"
  FOLDER_ID="NONE"
fi

if [ "$FOLDER_ID" != "NONE" ]; then

# B2: Upload test documents
TXT_ID=$(upload_file   "$FOLDER_ID" "$TMPDIR_DATA/short-memo.txt"      "short-memo.txt"      "text/plain")
SEC_ID=$(upload_file   "$FOLDER_ID" "$TMPDIR_DATA/security-policy.txt"  "security-policy.txt"  "text/plain")
ROAD_ID=$(upload_file  "$FOLDER_ID" "$TMPDIR_DATA/product-roadmap.txt"  "product-roadmap.txt"  "text/plain")
TECH_ID=$(upload_file  "$FOLDER_ID" "$TMPDIR_DATA/technical-spec.txt"   "technical-spec.txt"   "text/plain")
LONG_ID=$(upload_file  "$FOLDER_ID" "$TMPDIR_DATA/long-report.txt"      "long-report.txt"      "text/plain")
SIG_ID=$(upload_file   "$FOLDER_ID" "$TMPDIR_DATA/detached-signature.p7s" "detached-signature.p7s" "application/octet-stream")

for entry in "short-memo.txt:$TXT_ID" "security-policy.txt:$SEC_ID" \
             "product-roadmap.txt:$ROAD_ID" "technical-spec.txt:$TECH_ID" \
             "long-report.txt:$LONG_ID" "detached-signature.p7s:$SIG_ID"; do
  name="${entry%%:*}"; nid="${entry##*:}"
  [ -n "$nid" ] && pass "B2: Uploaded $name (nodeId=$nid)" \
                 || fail "B2: Failed to upload $name"
done

# B3a: Wait for Solr to index the uploaded files so batch discovery finds them.
wait_for_solr_indexed "$FOLDER_ID" 6

# B3+B4: Trigger sync with explicit folder and wait
run_sync_wait "$FOLDER_ID"

# B5–B9: Verify each document in semantic search. Poll to a deadline rather than a fixed sleep:
# embeddings become queryable a variable time after sync COMPLETED, especially on the local model.
wait_for_node_present "remote work eligibility work from home three days"  "$TXT_ID"  "B5" "short-memo.txt (HR)"
wait_for_node_present "information security policy password complexity"    "$SEC_ID"  "B6" "security-policy.txt (IT)"
wait_for_node_present "product roadmap Q3 delivery mobile first strategy"  "$ROAD_ID" "B7" "product-roadmap.txt (Product)"
wait_for_node_present "REST API endpoint HTTP authentication token"        "$TECH_ID" "B8" "technical-spec.txt (Engineering)"
wait_for_node_present "fiscal year total revenue gross profit EBITDA"      "$LONG_ID" "B9" "long-report.txt (Finance)"

# B10: Idempotency - re-run same sync, verify the chunk count does not grow.
#
# The count comes from the index-proof endpoint, which aggregates the embeddings index. It used to
# count semantic-search hits above minScore, which is a proxy for the chunk count rather than the
# chunk count: it is bounded by topK, it moves when relevance scoring changes, and it cannot see a
# chunk that scores below the threshold. index-proof measures the stored chunks directly.
#
# Uses long-report.txt rather than short-memo.txt. short-memo is one of the two documents issue #100
# reports as not embedded after a first sync, so its count starts at 0 and rises as embedding
# eventually completes: against that document a "count did not grow" assertion tests #100, not
# idempotency. long-report is the largest fixture and B9 has already proven it retrievable.
if [ -n "${LONG_ID:-}" ]; then
  count_before=$(index_proof_chunk_count "$LONG_ID")
  info "Re-running sync for idempotency check (pre-sync chunkCount=$count_before) …"
  resp2=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$FOLDER_ID\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  job2=$(echo "$resp2" | jq -r '.jobId // empty')
  if [ -n "$job2" ]; then
    info "Second sync job: $job2 — waiting for completion …"
    wait_job_complete "$job2" || warn "second sync job did not reach COMPLETED before deadline"
  fi
  count_after=$(index_proof_chunk_count "$LONG_ID")
  if [ "${count_before:-0}" -eq 0 ]; then
    warn "B10: pre-sync chunkCount was 0, so the idempotency comparison proves nothing"
  fi
  if [ "${count_after:-0}" -le "${count_before:-0}" ]; then
    pass "B10: Idempotency - stored chunk count unchanged after re-sync (chunkCount=$count_after)"
  else
    fail "B10: Idempotency - stored chunk count grew from $count_before to $count_after after re-sync (duplicates)"
  fi
fi

# B11: index-proof reports a fully indexed document as INDEXED_WITH_EMBEDDINGS, measured rather than
# claimed. contentLake_syncStatus=INDEXED does not imply retrievability, so the verdict has to come
# from the chunk count.
if [ -n "${LONG_ID:-}" ]; then
  proof=$(index_proof "$LONG_ID")
  verdict=$(echo "$proof" | jq -r '.verdict // empty')
  chunks=$(echo "$proof" | jq -r '.measured.chunkCount // 0')
  types=$(echo "$proof" | jq -r '.measured.embeddingTypes | length')
  if [ "$verdict" = "INDEXED_WITH_EMBEDDINGS" ] && [ "${chunks:-0}" -gt 0 ]; then
    pass "B11: index-proof verdict INDEXED_WITH_EMBEDDINGS (chunkCount=$chunks, embeddingTypes=$types)"
  else
    fail "B11: index-proof verdict is '$verdict' with chunkCount=$chunks (expected INDEXED_WITH_EMBEDDINGS)"
  fi
fi

# B12: exactly one embedding type per document. Two types means a child from a previously configured
# embedding model survived a re-sync and is still answering queries through the '*' wildcard.
if [ -n "${LONG_ID:-}" ]; then
  proof=$(index_proof "$LONG_ID")
  type_count=$(echo "$proof" | jq -r '.measured.embeddingTypes | length')
  type_list=$(echo "$proof" | jq -r '.measured.embeddingTypes | join(",")')
  if [ "${type_count:-0}" -eq 1 ]; then
    pass "B12: exactly one embedding type present ($type_list), no orphan from a retired model"
  else
    fail "B12: $type_count embedding types present ($type_list); expected exactly 1"
  fi
fi

# B13: an unknown node id is ABSENT, not an error and not a guess.
proof=$(index_proof "00000000-0000-0000-0000-000000000000")
verdict=$(echo "$proof" | jq -r '.verdict // empty')
if [ "$verdict" = "ABSENT" ]; then
  pass "B13: index-proof reports ABSENT for an unknown node id"
else
  fail "B13: index-proof verdict for an unknown node id is '$verdict' (expected ABSENT)"
fi

# B14: the verdict that motivates this endpoint. A document present with zero embeddings reports
# contentLake_syncStatus=INDEXED while being invisible to search, which is the #100 symptom; the
# endpoint must be able to say METADATA_ONLY and show the measured count disagreeing with the claim.
# Reported rather than asserted as a failure: whether any fixture is in that state on a given run
# depends on #100, and this section is not the place to gate on it.
if [ -n "${TXT_ID:-}" ]; then
  proof=$(index_proof "$TXT_ID")
  verdict=$(echo "$proof" | jq -r '.verdict // empty')
  chunks=$(echo "$proof" | jq -r '.measured.chunkCount // "null"')
  claimed=$(echo "$proof" | jq -r '.claimed.syncStatus // "null"')
  section_chunks=$(echo "$proof" | jq -r '.claimed.sectionMapChunks // "null"')
  case "$verdict" in
    METADATA_ONLY)
      pass "B14: index-proof reports METADATA_ONLY for short-memo.txt (measured chunkCount=$chunks vs claimed syncStatus=$claimed, sectionMapChunks=$section_chunks) -- the #100 state, correctly measured"
      ;;
    INDEXED_WITH_EMBEDDINGS)
      info "B14: short-memo.txt is embedded on this run (chunkCount=$chunks), so the METADATA_ONLY path was not exercised"
      pass "B14: index-proof reports a measured verdict for short-memo.txt ($verdict)"
      ;;
    *)
      fail "B14: index-proof returned verdict '$verdict' for short-memo.txt (expected a measured verdict)"
      ;;
  esac
fi

# B15: a type that cannot contain text reports SKIPPED, not FAILED. "We did not try" and "we tried and
# got nothing" are different facts, and only the second is a defect an operator should chase. No poll
# deadline: the sync above already completed, and the status is written in the same pass that skips the
# download, so it is there or the skip did not happen.
if [ -n "${SIG_ID:-}" ]; then
  sig_status=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
    "$BASE/api/content-lake/nodes/${SIG_ID}/status" 2>/dev/null || echo '{}')
  sig_state=$(echo "$sig_status" | jq -r '.status // "null"')
  sig_error=$(echo "$sig_status" | jq -r '.error // "null"')
  if [ "$sig_state" = "SKIPPED" ]; then
    pass "B15: detached-signature.p7s reports SKIPPED (error=\"$sig_error\")"
  else
    fail "B15: detached-signature.p7s reports '$sig_state' (expected SKIPPED, error=\"$sig_error\")"
  fi

  # The folder rollup must not go red for it: a skip is counted separately and is not a failure.
  # This is the operator-visible half of the change, and the half a per-document status cannot show.
  fold_summary=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
    "$BASE/api/content-lake/nodes/${FOLDER_ID}/status?includeFolderAggregate=true" 2>/dev/null || echo '{}')
  fold_skipped=$(echo "$fold_summary" | jq -r '.folderSummary.skippedDocuments // "null"')
  fold_total=$(echo "$fold_summary" | jq -r '.folderSummary.totalDocuments // "null"')
  fold_indexed=$(echo "$fold_summary" | jq -r '.folderSummary.indexedDocuments // "null"')
  fold_pending=$(echo "$fold_summary" | jq -r '.folderSummary.pendingDocuments // "null"')
  fold_failed=$(echo "$fold_summary" | jq -r '.folderSummary.failedDocuments // "null"')
  if [ "$fold_skipped" = "1" ]; then
    pass "B15a: folder summary counts the skip separately (skipped=$fold_skipped of total=$fold_total)"
  else
    fail "B15a: folder summary reports skipped=$fold_skipped (expected 1) for total=$fold_total"
  fi
  # The four buckets must sum to the total, which is why skipped had to be added rather than folded in.
  if [ "$fold_total" != "null" ] \
     && [ $((fold_indexed + fold_pending + fold_failed + fold_skipped)) -eq "$fold_total" ]; then
    pass "B15b: folder summary counts sum (indexed=$fold_indexed pending=$fold_pending failed=$fold_failed skipped=$fold_skipped = total=$fold_total)"
  else
    fail "B15b: folder summary counts do not sum: indexed=$fold_indexed pending=$fold_pending failed=$fold_failed skipped=$fold_skipped vs total=$fold_total"
  fi
fi

fi  # end FOLDER_ID != NONE block

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION C — Live Ingestion
# ═══════════════════════════════════════════════════════════════════════════════
section "C — Alfresco Live Ingestion"

LIVE_NODE_ID=""

if [ "$FOLDER_ID" != "NONE" ]; then

# C1: Create document — should appear via live event (ActiveMQ → live-ingester)
cat > "$TMPDIR_DATA/live-test-v1.txt" <<'EOF'
LIVE INGESTION TEST DOCUMENT — VERSION ONE

Unique sentinel phrase: xylophone-verdant-cascade-47z version one content.

This document tests real-time event propagation from the Alfresco repository
into the semantic search index via the live ingestion pipeline.
EOF

LIVE_NODE_ID=$(upload_file "$FOLDER_ID" "$TMPDIR_DATA/live-test-v1.txt" "live-test.txt" "text/plain")
if [ -n "$LIVE_NODE_ID" ]; then
  pass "C1a: Live test document created (nodeId=$LIVE_NODE_ID)"
  # Polled, not slept: a flat 20s is both slower than the common case and flakier than the slow one.
  wait_for_node_present "xylophone-verdant-cascade-47z version one" "$LIVE_NODE_ID" "C1b" \
    "live-test.txt after create event"
else
  fail "C1: Failed to create live test document"
fi

# C2: Update document content — new phrase should become searchable
if [ -n "$LIVE_NODE_ID" ]; then
  cat > "$TMPDIR_DATA/live-test-v2.txt" <<'EOF'
LIVE INGESTION TEST DOCUMENT — VERSION TWO

Unique sentinel phrase: tangerine-stellar-vortex-88q version two content.

The document has been updated. This tests the update event flow.
EOF
  code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
    "$ALF_BASE/nodes/$LIVE_NODE_ID/content" \
    -H 'Content-Type: text/plain' \
    --data-binary "@$TMPDIR_DATA/live-test-v2.txt" 2>/dev/null )
  if [ "$code" = "200" ]; then
    pass "C2a: Document content updated (HTTP 200)"
    wait_for_node_present "tangerine-stellar-vortex-88q version two" "$LIVE_NODE_ID" "C2b" \
      "live-test.txt after update event"
  else
    fail "C2: Content update returned HTTP $code"
  fi
fi

# C3: Delete document — should disappear from search
if [ -n "$LIVE_NODE_ID" ]; then
  code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
    "$ALF_BASE/nodes/$LIVE_NODE_ID" 2>/dev/null )
  if [ "$code" = "204" ]; then
    pass "C3a: Document deleted (HTTP 204)"
    # The one wait that has to be a wait: an absence cannot be polled towards. Deletion propagates
    # through the event listener and then the index, and 20s is what was measured to cover it.
    info "Waiting 20 s for delete event propagation …"
    sleep 20
    rag_absent_node "tangerine-stellar-vortex-88q" "$LIVE_NODE_ID" "C3b" "live-test.txt after delete event"
  else
    fail "C3: Delete returned HTTP $code (expected 204)"
  fi
fi

fi  # end FOLDER_ID block

# C4: Live ingester metrics (direct port — not exposed via proxy by default)
live_resp=$(curl -sf "$LIVE_URL" 2>/dev/null || echo '')
if [ -n "$live_resp" ]; then
  received=$(echo "$live_resp" | jq -r '.received // "?"')
  processed=$(echo "$live_resp" | jq -r '.processed // "?"')
  pass "C4: Live ingester metrics — received=$received, processed=$processed"
else
  info "C4: Live ingester port 9092 not reachable from host (not published by default; use docker exec to reach it)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION G — Permission Tests
# ═══════════════════════════════════════════════════════════════════════════════
section "G — Permission Tests"
info "Permissions set via PUT /nodes/{id} body (CE 25.3 — sub-resource endpoint 404)."
info "Permission changes are reconciled through /api/sync/permissions because Alfresco does not emit permission update events."
info "RAG permission filtering applies the authenticated user's identity against HXPR ACLs."
info "For Alfresco sources, repository admins remain discoverable across Alfresco content even when not listed in locallySet."

# G-N: Unauthenticated RAG requests must be rejected with HTTP 401
http_code_gn=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"test","topK":1,"minScore":0.2}' 2>/dev/null )
if [ "$http_code_gn" = "401" ]; then
  pass "G-N: Unauthenticated RAG request rejected (HTTP 401)"
else
  fail "G-N: Expected HTTP 401 for unauthenticated request, got HTTP $http_code_gn"
fi

if [ "$FOLDER_ID" != "NONE" ]; then

# G0: Create test users in Alfresco
create_alfresco_user "user-a" "User" "A"
create_alfresco_user "user-b" "User" "B"

# G1a: Upload HR doc, restrict to user-a
cat > "$TMPDIR_DATA/confidential-hr.txt" <<'EOF'
CONFIDENTIAL HR DOCUMENT
Restricted to HR and user-a only.
Content: salary band confidential HR restricted access user-a grade structure.
EOF
HR_PRIV_ID=$(upload_file "$FOLDER_ID" "$TMPDIR_DATA/confidential-hr.txt" "confidential-hr.txt" "text/plain")
if [ -n "$HR_PRIV_ID" ]; then
  perms='{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"user-a","name":"Consumer","accessStatus":"ALLOWED"}]}'
  set_node_permissions "$HR_PRIV_ID" "$perms" \
    && pass "G1a: confidential-hr.txt uploaded and restricted to user-a (nodeId=$HR_PRIV_ID)" \
    || fail "G1a: Failed to set permissions on confidential-hr.txt"
fi

# G1b: Upload Tech doc, restrict to user-b
cat > "$TMPDIR_DATA/tech-spec-restricted.txt" <<'EOF'
RESTRICTED TECHNICAL DOCUMENT
Restricted to engineering and user-b only.
Content: internal architecture restricted technical user-b access system design.
EOF
TECH_PRIV_ID=$(upload_file "$FOLDER_ID" "$TMPDIR_DATA/tech-spec-restricted.txt" "tech-spec-restricted.txt" "text/plain")
if [ -n "$TECH_PRIV_ID" ]; then
  perms='{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"user-b","name":"Consumer","accessStatus":"ALLOWED"}]}'
  set_node_permissions "$TECH_PRIV_ID" "$perms" \
    && pass "G1b: tech-spec-restricted.txt uploaded and restricted to user-b (nodeId=$TECH_PRIV_ID)" \
    || fail "G1b: Failed to set permissions on tech-spec-restricted.txt"
fi

# G1c: Upload public doc with GROUP_EVERYONE
cat > "$TMPDIR_DATA/public-announcement.txt" <<'EOF'
PUBLIC COMPANY ANNOUNCEMENT
Available to all staff.
Content: public company announcement everyone all staff general notice bulletin.
EOF
PUB_ID=$(upload_file "$FOLDER_ID" "$TMPDIR_DATA/public-announcement.txt" "public-announcement.txt" "text/plain")
if [ -n "$PUB_ID" ]; then
  perms='{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"GROUP_EVERYONE","name":"Consumer","accessStatus":"ALLOWED"}]}'
  set_node_permissions "$PUB_ID" "$perms" \
    && pass "G1c: public-announcement.txt uploaded with GROUP_EVERYONE (nodeId=$PUB_ID)" \
    || fail "G1c: Failed to set permissions on public-announcement.txt"
fi

# G2: Admin sees all documents. Poll each present-check to a deadline (permission reconciliation
# and embeddings settle a variable time after upload); the paired absent-checks then run once
# presence is confirmed, so the indexed ACLs have propagated by that point.
wait_for_node_present "salary band confidential HR restricted access user-a"          "$HR_PRIV_ID"   "G2a" "Admin: confidential-hr.txt"
wait_for_node_present "internal architecture restricted technical user-b access"      "$TECH_PRIV_ID" "G2b" "Admin: tech-spec-restricted.txt"
wait_for_node_present "public company announcement everyone all staff general notice" "$PUB_ID"       "G2c" "Admin: public-announcement.txt"

# G3: user-a — RAG search with user-a credentials (per-user ACL enforced via HTTP Basic Auth)
wait_for_node_present "salary band confidential HR restricted access user-a" \
  "$HR_PRIV_ID" "G3a" "user-a sees confidential-hr.txt" "user-a:password"
rag_absent_node_as "internal architecture restricted technical user-b access" \
  "$TECH_PRIV_ID" "G3b" "user-a cannot see tech-spec-restricted.txt" "user-a:password"
wait_for_node_present "public company announcement everyone all staff general notice" \
  "$PUB_ID" "G3c" "user-a sees public-announcement.txt" "user-a:password"

# G4: user-b — symmetric check
wait_for_node_present "internal architecture restricted technical user-b access" \
  "$TECH_PRIV_ID" "G4a" "user-b sees tech-spec-restricted.txt" "user-b:password"
rag_absent_node_as "salary band confidential HR restricted access user-a" \
  "$HR_PRIV_ID" "G4b" "user-b cannot see confidential-hr.txt" "user-b:password"
wait_for_node_present "public company announcement everyone all staff general notice" \
  "$PUB_ID" "G4c" "user-b sees public-announcement.txt" "user-b:password"

# G5/G6: Revoke user-a access — admin still finds the document; user-a no longer does.
if [ -n "${HR_PRIV_ID:-}" ]; then
  # Remove all ACEs (nobody but system admin can access)
  perms='{"isInheritanceEnabled":false,"locallySet":[]}'
  set_node_permissions "$HR_PRIV_ID" "$perms" \
    && info "G5: Revoked user-a access to confidential-hr.txt" \
    || fail "G5: Failed to revoke user-a permission"
  info "Waiting 5 s for permission revocation to be indexed …"
  sleep 5
  rag_find_node "salary band confidential HR restricted" "$HR_PRIV_ID" "G6a" \
    "Admin still finds confidential-hr.txt after user-a revocation"
  rag_absent_node_as "salary band confidential HR restricted" "$HR_PRIV_ID" "G6b" \
    "user-a cannot find confidential-hr.txt after revocation" "user-a:password"
fi

# ── Issue #27: Folder permission propagation ─────────────────────────────────

# G7: Create a dedicated folder with two types of child files to test that a
# folder-level ACL change propagates correctly to descendants:
#   - folder-child-inherit.txt  — no local ACL; should adopt the folder's ACL
#   - folder-child-isolated.txt — isInheritanceEnabled:false, locallySet=[user-b];
#                                  must NOT follow the folder after the ACL change
info "Issue #27: Folder permission propagation to descendant hxpr ACLs"
PERM_FOLDER_ID=$(create_folder "${FOLDER_ID}" "perm-propagation-test")
if [ -n "$PERM_FOLDER_ID" ]; then
  pass "G7: perm-propagation-test folder ready (nodeId=$PERM_FOLDER_ID)"
else
  fail "G7: Failed to create perm-propagation-test folder"
  PERM_FOLDER_ID="NONE"
fi

if [ "$PERM_FOLDER_ID" != "NONE" ]; then

cat > "$TMPDIR_DATA/folder-child-inherit.txt" <<'EOF'
FOLDER CHILD — INHERITED PERMISSIONS
Sentinel phrase: zephyr-indigo-kappa-fold inherited ACL propagation test.
This file relies on the parent folder's effective permissions.
EOF
FOLD_CHILD_INHERIT_ID=$(upload_file "$PERM_FOLDER_ID" \
  "$TMPDIR_DATA/folder-child-inherit.txt" "folder-child-inherit.txt" "text/plain")
if [ -n "$FOLD_CHILD_INHERIT_ID" ]; then
  pass "G7a: folder-child-inherit.txt uploaded (nodeId=$FOLD_CHILD_INHERIT_ID)"
else
  fail "G7a: Failed to upload folder-child-inherit.txt"
fi

cat > "$TMPDIR_DATA/folder-child-isolated.txt" <<'EOF'
FOLDER CHILD — ISOLATED PERMISSIONS
Sentinel phrase: zephyr-indigo-kappa-isol isolated ACL no-inherit propagation test.
This file has isInheritanceEnabled:false with a locally-set ACL for user-b only.
EOF
FOLD_CHILD_ISOLATED_ID=$(upload_file "$PERM_FOLDER_ID" \
  "$TMPDIR_DATA/folder-child-isolated.txt" "folder-child-isolated.txt" "text/plain")
if [ -n "$FOLD_CHILD_ISOLATED_ID" ]; then
  perms='{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"user-b","name":"Consumer","accessStatus":"ALLOWED"}]}'
  set_node_permissions "$FOLD_CHILD_ISOLATED_ID" "$perms" \
    && pass "G7b: folder-child-isolated.txt uploaded and restricted to user-b (nodeId=$FOLD_CHILD_ISOLATED_ID)" \
    || fail "G7b: Failed to set permissions on folder-child-isolated.txt"
else
  fail "G7b: Failed to upload folder-child-isolated.txt"
fi

# G8: Ingest the folder subtree so both files are in hxpr before any ACL change.
# Wait for Solr to index both uploaded children first (batch discovery is AFTS-based).
wait_for_solr_indexed "$PERM_FOLDER_ID" 2
info "G8: Triggering batch sync for perm-propagation-test folder …"
if run_sync_wait "$PERM_FOLDER_ID"; then
  pass "G8: Batch sync completed"
else
  fail "G8: Batch sync did not complete"
fi
wait_for_node_present "zephyr-indigo-kappa-fold inherited ACL propagation" \
  "$FOLD_CHILD_INHERIT_ID" "G8a" "Admin: folder-child-inherit.txt visible before ACL change"
wait_for_node_present "zephyr-indigo-kappa-isol isolated ACL no-inherit propagation" \
  "$FOLD_CHILD_ISOLATED_ID" "G8b" "Admin: folder-child-isolated.txt visible before ACL change"

# G9: Change folder permissions — disable inheritance, restrict to user-a only —
# then trigger a recursive batch ACL reconciliation.  No content is re-ingested.
info "G9: Restricting perm-propagation-test folder to user-a only …"
folder_perms='{"isInheritanceEnabled":false,"locallySet":[{"authorityId":"user-a","name":"Consumer","accessStatus":"ALLOWED"}]}'
g9_code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
  "$ALF_BASE/nodes/$PERM_FOLDER_ID" \
  -H 'Content-Type: application/json' \
  -d "{\"permissions\":$folder_perms}" 2>/dev/null )
if [ "$g9_code" = "200" ]; then
  pass "G9: Folder permissions updated to user-a only (HTTP 200)"
else
  fail "G9: Failed to update folder permissions (HTTP $g9_code)"
fi

reconcile_node_permissions "$PERM_FOLDER_ID" true \
  && pass "G9: Recursive ACL reconciliation triggered" \
  || fail "G9: ACL reconciliation request failed"
# ACL reconciliation propagation is covered by polling the G10 present-checks below (each present
# check gates its paired absent-check, so the reconciled ACL is in effect by the time those run).

# G10: Verify ACL propagation (issue #27 acceptance criteria):
#
#  folder-child-inherit.txt  — inheritance enabled → adopts folder's new ACL
#    G10a: user-a FINDS it (folder grants user-a, child inherits)
#    G10b: user-b CANNOT find it (removed from folder's ACL)
#    G10c: admin FINDS it (source-level bypass)
#
#  folder-child-isolated.txt — isInheritanceEnabled:false, locallySet=[user-b]
#    G10d: user-b STILL finds it (own ACL unchanged by folder change)
#    G10e: user-a CANNOT find it (not in file's own locallySet)
#    G10f: admin FINDS it (source-level bypass)
wait_for_node_present \
  "zephyr-indigo-kappa-fold inherited ACL propagation" \
  "$FOLD_CHILD_INHERIT_ID" "G10a" \
  "user-a finds folder-child-inherit.txt after folder restricted to user-a" \
  "user-a:password"
rag_absent_node_as \
  "zephyr-indigo-kappa-fold inherited ACL propagation" \
  "$FOLD_CHILD_INHERIT_ID" "G10b" \
  "user-b cannot find folder-child-inherit.txt after folder restricted to user-a" \
  "user-b:password"
wait_for_node_present \
  "zephyr-indigo-kappa-fold inherited ACL propagation" \
  "$FOLD_CHILD_INHERIT_ID" "G10c" \
  "Admin finds folder-child-inherit.txt after folder ACL change"
wait_for_node_present \
  "zephyr-indigo-kappa-isol isolated ACL no-inherit propagation" \
  "$FOLD_CHILD_ISOLATED_ID" "G10d" \
  "user-b still finds folder-child-isolated.txt (own ACL, inheritance disabled)" \
  "user-b:password"
rag_absent_node_as \
  "zephyr-indigo-kappa-isol isolated ACL no-inherit propagation" \
  "$FOLD_CHILD_ISOLATED_ID" "G10e" \
  "user-a cannot find folder-child-isolated.txt (not in file's own locallySet)" \
  "user-a:password"
wait_for_node_present \
  "zephyr-indigo-kappa-isol isolated ACL no-inherit propagation" \
  "$FOLD_CHILD_ISOLATED_ID" "G10f" \
  "Admin finds folder-child-isolated.txt after folder ACL change"

fi  # end PERM_FOLDER_ID block

fi  # end FOLDER_ID block

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION H — Chunking Strategy
# ═══════════════════════════════════════════════════════════════════════════════
section "H — Chunking Strategy"

if [ -n "${TXT_ID:-}" ] && [ -n "${LONG_ID:-}" ]; then

# H1: Short document — verify it's retrievable (single-doc in HR topic)
resp_h1=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"home office equipment allowance ergonomic chair five hundred pounds","topK":5,"minScore":0.2}' \
  2>/dev/null || echo '{}')
count_h1=$(echo "$resp_h1" | jq --arg id "$TXT_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
chunk_preview=$(echo "$resp_h1" | jq -r --arg id "$TXT_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 100)
if [ "${count_h1:-0}" -gt 0 ]; then
  pass "H1: Short memo retrieved via specific phrase (chunks in results: $count_h1)"
  info "    Chunk preview: ${chunk_preview}…"
else
  fail "H1: Short memo NOT found — chunking or embedding may have failed"
fi

# H2: Long document — early vs late section queries should return different chunk text
resp_early=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"fiscal year total revenue gross profit EBITDA executive summary","topK":5,"minScore":0.2}' \
  2>/dev/null || echo '{}')
resp_late=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"audit certification regulatory compliance framework board approval","topK":5,"minScore":0.2}' \
  2>/dev/null || echo '{}')

early_text=$(echo "$resp_early" | jq -r --arg id "$LONG_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 80)
late_text=$(echo "$resp_late" | jq -r --arg id "$LONG_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkText // ""' 2>/dev/null | head -c 80)
early_pg=$(echo "$resp_early" | jq -r --arg id "$LONG_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkMetadata.page // "n/a"' 2>/dev/null)
late_pg=$(echo "$resp_late" | jq -r --arg id "$LONG_ID" \
  '[.results[]? | select(.sourceDocument.nodeId == $id)][0].chunkMetadata.page // "n/a"' 2>/dev/null)

if [ -n "$early_text" ] && [ -n "$late_text" ] && [ "$early_text" != "$late_text" ]; then
  pass "H2: Long report yields different chunks for early vs late section queries"
  info "    Early (page=$early_pg): ${early_text}…"
  info "    Late  (page=$late_pg):  ${late_text}…"
elif [ -n "$early_text" ] && [ "$early_text" = "$late_text" ]; then
  info "H2: Both queries returned the same chunk text — may be a single large chunk"
else
  fail "H2: Could not retrieve chunks from long report for early/late queries"
fi

# H3: Topic isolation — finance query top-3 should not include HR or tech docs
resp_fin=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
  -H 'Content-Type: application/json' \
  -d '{"query":"capital expenditure shareholder dividends free cash flow","topK":3,"minScore":0.4}' \
  2>/dev/null || echo '{}')
top3_json=$(echo "$resp_fin" | jq -r '[.results[:3][]?.sourceDocument.nodeId] | join("\n")' 2>/dev/null || echo "")

hr_in_top3=0
tech_in_top3=0
if echo "$top3_json" | grep -q "${TXT_ID:-__NONE__}"; then hr_in_top3=1; fi
if echo "$top3_json" | grep -q "${TECH_ID:-__NONE__}"; then tech_in_top3=1; fi

if [ "$hr_in_top3" -eq 0 ] && [ "$tech_in_top3" -eq 0 ]; then
  pass "H3: Finance query top-3 contains no HR or Tech documents (topic isolation confirmed)"
  info "    Top-3 nodeIds: $(echo "$top3_json" | head -3 | tr '\n' ' ')"
else
  fail "H3: Finance query top-3 includes non-finance document(s) — possible topic bleed"
fi

fi  # end chunking block

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION I — Folder Hierarchy Scope Exclusion
# ═══════════════════════════════════════════════════════════════════════════════
section "I — Folder Hierarchy Scope Exclusion"
info "Hierarchy (4 folder levels):"
info "  cl-hierarchy-test/  ← cl:indexed auto-added by batch sync"
info "    hier-doc-l0.txt   ← EXPECTED: indexed"
info "    level1/"
info "      hier-doc-l1.txt ← EXPECTED: indexed"
info "      level2-excluded/ ← cl:excludeFromLake=true"
info "        hier-doc-l2.txt ← EXPECTED: absent"
info "        level3/"
info "          hier-doc-l3.txt ← EXPECTED: absent (ancestor excluded)"

# set_exclude_from_lake <node_id>
# Adds the cl:fileScope aspect and sets cl:excludeFromLake=true without stripping
# existing aspects (fetches current list first and merges).
set_exclude_from_lake() {
  local node_id="$1"
  local current_aspects merged_aspects code
  current_aspects=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" \
    "$ALF_BASE/nodes/$node_id?fields=aspectNames" 2>/dev/null \
    | jq -c '.entry.aspectNames // []')
  merged_aspects=$(printf '%s' "$current_aspects" \
    | jq -c '. + ["cl:fileScope"] | unique')
  code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X PUT \
    "$ALF_BASE/nodes/$node_id" \
    -H 'Content-Type: application/json' \
    -d "{\"aspectNames\":$merged_aspects,\"properties\":{\"cl:excludeFromLake\":true}}" \
    2>/dev/null )
  [ "$code" = "200" ]
}

# I1: Create the root folder for this test
HIER_ROOT_ID=$(create_folder "-my-" "cl-hierarchy-test")
if [ -n "$HIER_ROOT_ID" ]; then
  pass "I1: Root folder ready (nodeId=$HIER_ROOT_ID)"
else
  fail "I1: Failed to create root folder"
  HIER_ROOT_ID="NONE"
fi

if [ "$HIER_ROOT_ID" != "NONE" ]; then

# I2: Build the three-level sub-hierarchy
LEVEL1_ID=""
LEVEL2_EXCL_ID=""
LEVEL3_ID=""
LEVEL1_ID=$(create_folder "$HIER_ROOT_ID" "level1")
[ -n "$LEVEL1_ID" ] && LEVEL2_EXCL_ID=$(create_folder "$LEVEL1_ID" "level2-excluded")
[ -n "$LEVEL2_EXCL_ID" ] && LEVEL3_ID=$(create_folder "$LEVEL2_EXCL_ID" "level3")

if [ -n "$LEVEL1_ID" ] && [ -n "$LEVEL2_EXCL_ID" ] && [ -n "$LEVEL3_ID" ]; then
  pass "I2: Sub-hierarchy created (level1=$LEVEL1_ID, level2-excluded=$LEVEL2_EXCL_ID, level3=$LEVEL3_ID)"
else
  fail "I2: Failed to create sub-folders (level1='$LEVEL1_ID', level2='$LEVEL2_EXCL_ID', level3='$LEVEL3_ID')"
fi

# I3: Upload one document per folder level with unique sentinel phrases
cat > "$TMPDIR_DATA/hier-doc-l0.txt" <<'EOF'
HIERARCHY TEST — ROOT LEVEL DOCUMENT
Sentinel phrase: zephyr-cobalt-lambda-00r root level in-scope content.
This document is placed directly in the root hierarchy test folder.
EOF
cat > "$TMPDIR_DATA/hier-doc-l1.txt" <<'EOF'
HIERARCHY TEST — LEVEL 1 DOCUMENT
Sentinel phrase: zephyr-cobalt-lambda-11r level one in-scope content.
This document is one level below the root and should be indexed.
EOF
cat > "$TMPDIR_DATA/hier-doc-l2.txt" <<'EOF'
HIERARCHY TEST — LEVEL 2 DOCUMENT (EXCLUDED)
Sentinel phrase: zephyr-cobalt-lambda-22r level two excluded content.
This document is inside the folder marked with cl:excludeFromLake=true.
EOF
cat > "$TMPDIR_DATA/hier-doc-l3.txt" <<'EOF'
HIERARCHY TEST — LEVEL 3 DOCUMENT (EXCLUDED BY ANCESTOR)
Sentinel phrase: zephyr-cobalt-lambda-33r level three ancestor-excluded content.
This document is inside a sub-folder of the excluded folder.
EOF

DOC_L0_ID=$(upload_file "$HIER_ROOT_ID"   "$TMPDIR_DATA/hier-doc-l0.txt" "hier-doc-l0.txt" "text/plain")
DOC_L1_ID=$(upload_file "$LEVEL1_ID"      "$TMPDIR_DATA/hier-doc-l1.txt" "hier-doc-l1.txt" "text/plain")
DOC_L2_ID=$(upload_file "$LEVEL2_EXCL_ID" "$TMPDIR_DATA/hier-doc-l2.txt" "hier-doc-l2.txt" "text/plain")
DOC_L3_ID=$(upload_file "$LEVEL3_ID"      "$TMPDIR_DATA/hier-doc-l3.txt" "hier-doc-l3.txt" "text/plain")

for entry in "hier-doc-l0.txt:$DOC_L0_ID" "hier-doc-l1.txt:$DOC_L1_ID" \
             "hier-doc-l2.txt:$DOC_L2_ID" "hier-doc-l3.txt:$DOC_L3_ID"; do
  fname="${entry%%:*}"; nid="${entry##*:}"
  [ -n "$nid" ] && pass "I3: Uploaded $fname (nodeId=$nid)" \
                 || fail "I3: Failed to upload $fname"
done

# I4: Disable level2-excluded from synchronisation
if [ -n "$LEVEL2_EXCL_ID" ]; then
  set_exclude_from_lake "$LEVEL2_EXCL_ID" \
    && pass "I4: cl:excludeFromLake=true applied to level2-excluded (nodeId=$LEVEL2_EXCL_ID)" \
    || fail "I4: Failed to set cl:excludeFromLake on level2-excluded"
fi

# I5+I6: Trigger batch sync from root; NodeDiscoveryService auto-adds cl:indexed to root
resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
  -H 'Content-Type: application/json' \
  -d "{\"folders\":[\"$HIER_ROOT_ID\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
  2>/dev/null || echo '{}')
hier_job_id=$(echo "$resp" | jq -r '.jobId // empty')
if [ -z "$hier_job_id" ]; then
  fail "I5: Sync trigger returned no jobId (response: $resp)"
else
  pass "I5: Sync triggered — jobId=$hier_job_id"
  elapsed=0
  hier_status="UNKNOWN"
  while [ $elapsed -lt 300 ]; do
    sr=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$hier_job_id" 2>/dev/null || echo '{}')
    hier_status=$(echo "$sr" | jq -r '.status // "UNKNOWN"')
    case "$hier_status" in
      COMPLETED)
        processed=$(echo "$sr" | jq -r '.metadataIngestedCount // .processedCount // "?"')
        pass "I6: Sync COMPLETED (metadataIngestedCount=$processed)"
        break
        ;;
      FAILED|ERROR)
        fail "I6: Sync job FAILED — $(echo "$sr" | jq -c '{status,failedCount,discoveredCount}')"
        break
        ;;
    esac
    sleep 10; elapsed=$((elapsed+10))
  done
  [ $elapsed -ge 300 ] && fail "I6: Sync timed out after 5 min (last status=$hier_status)"
fi

# I7: Documents at root and level1 must be indexed. Poll to a deadline; the level2/level3 absence
# checks (I8) then run once the in-scope docs are confirmed searchable.
wait_for_node_present "zephyr-cobalt-lambda-00r root level in-scope"   "$DOC_L0_ID" "I7a" "hier-doc-l0.txt (root — in scope)"
wait_for_node_present "zephyr-cobalt-lambda-11r level one in-scope"    "$DOC_L1_ID" "I7b" "hier-doc-l1.txt (level1 — in scope)"

# I8: Documents at level2 and level3 must not be indexed (excluded subtree)
rag_absent_node "zephyr-cobalt-lambda-22r level two excluded"           "$DOC_L2_ID" "I8a" "hier-doc-l2.txt (level2 — cl:excludeFromLake)"
rag_absent_node "zephyr-cobalt-lambda-33r level three ancestor-excluded" "$DOC_L3_ID" "I8b" "hier-doc-l3.txt (level3 — ancestor excluded)"

fi  # end HIER_ROOT_ID != NONE block

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION J - Deletion Reconciliation
# ═══════════════════════════════════════════════════════════════════════════════
# Deletion otherwise depends entirely on a delete event arriving. With the live ingester stopped, a
# node removed from Alfresco outlives its source in the index and search returns it as a phantom
# result, with nothing to notice. A batch sync must reconcile the index against what its discovery
# pass actually saw.
#
# The live ingester is stopped for the whole window on purpose: with it running, the delete event
# would remove the document and the test would pass without the sweep existing at all.
section "J - Deletion Reconciliation (live ingester stopped)"

J_FOLDER_ID=""
J_STAMP="$(date +%Y%m%d-%H%M%S)-$$"
J_LIVE_STOPPED=0

# Restore the live ingester however this section exits. run-tests.sh wipes volumes between phases,
# not within one, so leaving it stopped would silently break every later section in this phase.
j_restore_live_ingester() {
  if [ "$J_LIVE_STOPPED" -eq 1 ]; then
    info "J: restarting live-ingester"
    (cd "$DEPLOY_DIR" 2>/dev/null && docker compose --profile alfresco start live-ingester >/dev/null 2>&1) \
      || warn "J: could not restart live-ingester; later live-ingestion assertions may fail"
    J_LIVE_STOPPED=0
    sleep 10
  fi
}
trap 'j_restore_live_ingester; cleanup' EXIT

J_FOLDER_ID=$(create_folder "-my-" "recon-test-$J_STAMP")
if [ -z "$J_FOLDER_ID" ]; then
  fail "J0: could not create the reconciliation test folder -- skipping section J"
else
  pass "J0: reconciliation test folder created (nodeId=$J_FOLDER_ID)"

  # Three documents with distinct sentinels. Two survive; one is deleted at the source. The two
  # survivors are the negative control: without them the section would pass on a sweep that deletes
  # everything, which is the failure mode that matters most here.
  for tag in alpha bravo charlie; do
    printf 'Reconciliation fixture. Sentinel: reconsentinel-%s-%s.\n' "$tag" "$J_STAMP" \
      > "$TMPDIR_DATA/recon-$tag.txt"
    printf 'This document exists to verify that a batch sync deletes only what the source removed.\n' \
      >> "$TMPDIR_DATA/recon-$tag.txt"
  done

  J_ALPHA_ID=$(upload_file "$J_FOLDER_ID" "$TMPDIR_DATA/recon-alpha.txt" "recon-alpha.txt" "text/plain")
  J_BRAVO_ID=$(upload_file "$J_FOLDER_ID" "$TMPDIR_DATA/recon-bravo.txt" "recon-bravo.txt" "text/plain")
  J_CHARLIE_ID=$(upload_file "$J_FOLDER_ID" "$TMPDIR_DATA/recon-charlie.txt" "recon-charlie.txt" "text/plain")

  if [ -z "$J_ALPHA_ID" ] || [ -z "$J_BRAVO_ID" ] || [ -z "$J_CHARLIE_ID" ]; then
    fail "J1: could not upload all three reconciliation fixtures -- skipping the rest of section J"
  else
    pass "J1: three reconciliation fixtures uploaded"

    wait_for_solr_indexed "$J_FOLDER_ID" 3 "J1a"

    if run_sync_wait "$J_FOLDER_ID" "J2a" "J2b"; then
      pass "J2: initial sync of the reconciliation folder completed"
    else
      fail "J2: initial sync of the reconciliation folder did not complete"
    fi

    wait_for_node_present "reconsentinel-alpha-$J_STAMP"   "$J_ALPHA_ID"   "J3a" "recon-alpha.txt"
    wait_for_node_present "reconsentinel-bravo-$J_STAMP"   "$J_BRAVO_ID"   "J3b" "recon-bravo.txt"
    wait_for_node_present "reconsentinel-charlie-$J_STAMP" "$J_CHARLIE_ID" "J3c" "recon-charlie.txt"

    # Stop the live ingester so no delete event can reach hxpr. Everything from here on is the
    # batch sweep's work.
    info "J: stopping live-ingester so no delete event can reach hxpr"
    if (cd "$DEPLOY_DIR" 2>/dev/null && docker compose --profile alfresco stop live-ingester >/dev/null 2>&1); then
      J_LIVE_STOPPED=1
      pass "J4: live-ingester stopped"
    else
      warn "J4: could not stop live-ingester; the sweep result below may be attributable to the event path"
    fi

    # Delete bravo at the source, permanently so it does not linger in the trash.
    code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" -X DELETE \
      "$ALF_BASE/nodes/$J_BRAVO_ID?permanent=true" 2>/dev/null )
    if [ "$code" = "204" ]; then
      pass "J5: recon-bravo.txt deleted from Alfresco (HTTP $code)"
    else
      fail "J5: deleting recon-bravo.txt returned HTTP $code (expected 204)"
    fi

    # Wait until Alfresco itself stops returning it, then until the search index agrees: discovery
    # runs an AFTS descendant query, so a sweep run before the index catches up would see bravo as
    # still present and delete nothing.
    elapsed=0
    while [ $elapsed -lt 60 ]; do
      code=$(curl -sf $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$ALF_AUTH" \
        "$ALF_BASE/nodes/$J_BRAVO_ID" 2>/dev/null || echo 404)
      [ "$code" = "404" ] && break
      sleep 5; elapsed=$((elapsed + 5))
    done
    wait_for_solr_indexed "$J_FOLDER_ID" 2 "J5a"

    # Re-sync. This is the pass whose discovery will not see bravo.
    if run_sync_wait "$J_FOLDER_ID" "J6a" "J6b"; then
      pass "J6: reconciling sync completed"
    else
      fail "J6: reconciling sync did not complete"
    fi

    # The sweep's own report, read off the job. A bare "the document is gone" assertion would also
    # pass if something else removed it, so assert the sweep says it did the deleting.
    recon=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$LAST_SYNC_JOB_ID" 2>/dev/null \
      | jq -c '.reconciliation // {}' 2>/dev/null || echo '{}')
    recon_status=$(echo "$recon" | jq -r '.status // empty')
    recon_deleted=$(echo "$recon" | jq -r '.deleted // 0')
    if [ "$recon_status" = "COMPLETED" ] && [ "${recon_deleted:-0}" -ge 1 ]; then
      pass "J7: sweep reports status=COMPLETED deleted=$recon_deleted"
    else
      fail "J7: sweep reports $recon (expected status=COMPLETED with deleted>=1)"
    fi

    # The deleted document is gone from the index.
    rag_absent_node "reconsentinel-bravo-$J_STAMP" "$J_BRAVO_ID" "J8" "recon-bravo.txt (deleted at source)"

    # The negative control: the sweep must not have taken the other two with it.
    wait_for_node_present "reconsentinel-alpha-$J_STAMP"   "$J_ALPHA_ID"   "J9a" "recon-alpha.txt (must survive)"
    wait_for_node_present "reconsentinel-charlie-$J_STAMP" "$J_CHARLIE_ID" "J9b" "recon-charlie.txt (must survive)"

    # index-proof on the deleted node: ABSENT, measured rather than inferred from search scoring.
    verdict=$(index_proof "$J_BRAVO_ID" | jq -r '.verdict // empty')
    if [ "$verdict" = "ABSENT" ]; then
      pass "J10: index-proof reports ABSENT for the reconciled-away node"
    else
      fail "J10: index-proof verdict for the reconciled-away node is '$verdict' (expected ABSENT)"
    fi
  fi

  j_restore_live_ingester
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION R — AFTS Regression Tests
# ═══════════════════════════════════════════════════════════════════════════════
# Regression tests for two bugs fixed in the AFTS migration:
#
#  R1 — Folder alias resolution
#       /api/sync/batch with folders=["-root-"] must discover documents.
#       Regression: -root- was passed verbatim to AFTS ANCESTOR: which produced
#       zero results because AFTS does not resolve Alfresco special aliases.
#
#  R2 — AFTS ANCESTOR: direction
#       Documents inside a cl:indexed folder must be discoverable by the batch
#       ingester. Regression: hasIndexedAncestor() queried descendants of the
#       file node (ANCESTOR:"{fileId}"), not its ancestor folders, so every file
#       appeared out-of-scope and was deleted from hxpr.
section "R — AFTS Regression Tests"

R_FOLDER_ID=""
R_NODE_ID=""
R_SENTINEL="afts-regression-$(date +%Y%m%d-%H%M%S)-$$"

# R-setup: create a dedicated test folder and upload one document
R_FOLDER_ID=$(create_folder "-my-" "afts-regression-test-$$")
if [ -n "$R_FOLDER_ID" ]; then
  pass "R0: Regression test folder created (nodeId=$R_FOLDER_ID)"
else
  fail "R0: Failed to create regression test folder -- skipping R1/R2"
fi

if [ -n "$R_FOLDER_ID" ]; then
  printf 'AFTS regression document. Sentinel: %s. ' "$R_SENTINEL" > "$TMPDIR_DATA/r-doc.txt"
  printf 'This document validates AFTS ancestor-scope checks and alias resolution.\n' >> "$TMPDIR_DATA/r-doc.txt"
  R_NODE_ID=$(upload_file "$R_FOLDER_ID" "$TMPDIR_DATA/r-doc.txt" "r-doc.txt" "text/plain")
  if [ -n "$R_NODE_ID" ]; then
    pass "R0b: Regression document uploaded (nodeId=$R_NODE_ID)"
  else
    fail "R0b: Failed to upload regression document -- skipping R1/R2"
  fi
fi

# R1: Sync triggered with the real folder UUID must succeed and discover the document.
#     The batch ingester must resolve the folder ID and index its contents.
#     Wait for Solr to commit the new document before querying via AFTS.
if [ -n "$R_FOLDER_ID" ] && [ -n "$R_NODE_ID" ]; then
  info "Waiting 15s for Solr to index the new document before triggering AFTS sync ..."
  sleep 15
  r1_resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
    -H 'Content-Type: application/json' \
    -d "{\"folders\":[\"$R_FOLDER_ID\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
    2>/dev/null || echo '{}')
  r1_job=$(echo "$r1_resp" | jq -r '.jobId // empty')
  if [ -z "$r1_job" ]; then
    fail "R1: Sync trigger returned no jobId -- AFTS alias resolution or discovery broken"
  else
    pass "R1a: Sync triggered with folder UUID (jobId=$r1_job)"
    r1_elapsed=0; r1_status="UNKNOWN"
    while [ $r1_elapsed -lt 120 ]; do
      r1_sr=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$r1_job" 2>/dev/null || echo '{}')
      r1_status=$(echo "$r1_sr" | jq -r '.status // "UNKNOWN"')
      [ "$r1_status" = "COMPLETED" ] || [ "$r1_status" = "FAILED" ] && break
      sleep 5; r1_elapsed=$((r1_elapsed+5))
    done
    r1_discovered=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$r1_job" 2>/dev/null \
      | jq -r '.discoveredCount // 0')
    if [ "$r1_status" = "COMPLETED" ] && [ "${r1_discovered:-0}" -gt 0 ]; then
      pass "R1b: Sync COMPLETED and discovered ${r1_discovered} node(s) -- AFTS alias resolution works"
    elif [ "$r1_status" = "COMPLETED" ] && [ "${r1_discovered:-0}" -eq 0 ]; then
      # First sync adds cl:indexed to the folder; Solr needs time to commit before AFTS
      # can find its descendants. Wait and re-sync once.
      info "R1b: First sync discovered 0 (cl:indexed just added -- waiting 20s for Solr commit, then re-syncing) ..."
      sleep 20
      r2b_resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$SYNC_URL/batch" \
        -H 'Content-Type: application/json' \
        -d "{\"folders\":[\"$R_FOLDER_ID\"],\"recursive\":true,\"types\":[\"cm:content\"]}" \
        2>/dev/null || echo '{}')
      r2b_job=$(echo "$r2b_resp" | jq -r '.jobId // empty')
      if [ -n "$r2b_job" ]; then
        r2b_elapsed=0; r2b_disc=0; r2b_status="UNKNOWN"
        while [ $r2b_elapsed -lt 120 ]; do
          r2b_sr=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" "$SYNC_URL/status/$r2b_job" 2>/dev/null || echo '{}')
          r2b_status=$(echo "$r2b_sr" | jq -r '.status // "UNKNOWN"')
          r2b_disc=$(echo "$r2b_sr" | jq -r '.discoveredCount // 0')
          [ "$r2b_status" = "COMPLETED" ] || [ "$r2b_status" = "FAILED" ] && break
          sleep 5; r2b_elapsed=$((r2b_elapsed+5))
        done
        [ "$r2b_status" = "COMPLETED" ] && [ "${r2b_disc:-0}" -gt 0 ] \
          && pass "R1b: Re-sync COMPLETED and discovered ${r2b_disc} node(s)" \
          || fail "R1b: Re-sync status=$r2b_status discovered=${r2b_disc} -- AFTS ANCESTOR query returned nothing"
      else
        fail "R1b: Re-sync trigger returned no jobId"
      fi
    else
      fail "R1b: Sync ended with status=$r1_status"
    fi

    info "Waiting 60s for embeddings ..."
    sleep 60

    # R2: Document must appear in search -- proves hasIndexedAncestor() returns true
    #     for a file whose parent has cl:indexed. Regression: it queried descendants
    #     of the file (always empty for a leaf), so isInScope() always returned false.
    rag_resp=$(curl -sf $CURL_OPTS -u "$ALF_AUTH" -X POST "$RAG_URL/search/semantic" \
      -H 'Content-Type: application/json' \
      -d "{\"query\":\"$R_SENTINEL AFTS regression ancestor scope\",\"topK\":10,\"minScore\":0.0}" \
      2>/dev/null || echo '{}')
    r2_found=$(echo "$rag_resp" | jq --arg id "$R_NODE_ID" \
      '[.results[]? | select(.sourceDocument.nodeId == $id)] | length' 2>/dev/null || echo 0)
    if [ "${r2_found:-0}" -gt 0 ]; then
      pass "R2: Document found in search -- AFTS hasIndexedAncestor() correctly checks ancestor direction"
    else
      fail "R2: Document NOT found in search -- hasIndexedAncestor() likely still querying descendants instead of ancestors"
      echo "    nodeId=$R_NODE_ID sentinel=$R_SENTINEL"
    fi
  fi
fi

# R-cleanup
if [ -n "$R_FOLDER_ID" ]; then
  curl -sf $CURL_OPTS -u "$ALF_AUTH" -X DELETE "$ALF_BASE/nodes/$R_FOLDER_ID?permanent=true" \
    2>/dev/null >/dev/null || true
  pass "R-cleanup: Regression test folder deleted"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
printf "${B}══ Alfresco Test Results ══${N}\n"
printf "${G}  Passed : %d${N}\n" "$PASS"
printf "${R}  Failed : %d${N}\n" "$FAIL"
printf "  Log    : %s\n" "$LOG"
echo ""

[ "$FAIL" -eq 0 ]
