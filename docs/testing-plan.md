# App for OpenArch -- End-to-End Testing Plan

This document defines the full test suite for validating an App for OpenArch deployment against
Alfresco and Nuxeo. Each test case specifies: the action (curl command), the expected HTTP
status, and the key fields to verify in the response.

Tests are grouped into eight sections and should be executed in order.

---

## Quick Reference

| Service | Public URL | Auth |
|---|---|---|
| Alfresco REST API | `http://localhost/alfresco/api/-default-/public/alfresco/versions/1` | `admin:admin` |
| Alfresco batch-ingester | `http://localhost/api/sync/configured` | `admin:admin` |
| Alfresco live status | `http://localhost:9092/api/live/status` | -- (port not published by default) |
| Nuxeo REST API | `http://localhost:8081/nuxeo/api/v1` | `Administrator:Administrator` |
| Nuxeo batch-ingester | `http://localhost/api/sync/configured` | `Administrator:Administrator` |
| Batch sync status | `http://localhost/api/sync/status` | credentials of whichever ingester the profile routes to |
| RAG service | `http://localhost/api/rag` | `admin:admin` (or any account valid in a configured source) |
| Health and info probes | `/actuator/health`, `/actuator/info` on any service | -- (public) |
| Any other actuator path | `/actuator/metrics` on any service | same credentials as that service's API |

> **Stack profile:** Use `make up-alfresco` for sections A-C and G (Alfresco).
> Use `make up-nuxeo` for sections D-E (Nuxeo-only; also starts HXPR + RAG but not Alfresco services).
> Use `make up-full` for section F cross-source tests (both source types simultaneously).
>
> **Nginx routing:** In each mode the nginx proxy routes `/api/sync/*` to the ingester for
> that mode only. No `?sourceType=` parameter is needed -- just `POST /api/sync/configured`.

---

## 0. Prerequisites

### 0.1 Start the stack

**Alfresco-only phase** (sections A-C, G, H):
```bash
cd content-lake-app-deployment
make up-alfresco
```

**Nuxeo-only phase** (sections D-E): start the sibling Nuxeo stack first, then content-lake in nuxeo profile:
```bash
cd ../nuxeo-deployment && docker compose up -d
cd ../content-lake-app-deployment
make up-nuxeo
```

**Cross-source phase** (section F): both sources running simultaneously:
```bash
# nuxeo-deployment must already be running
make up-full
```

Wait until all services are healthy before running tests. The automated test scripts in
`test/` handle startup and teardown automatically.

### 0.2 Create test users

**Alfresco** -- via the Control Center admin console at `http://localhost/admin` or REST:

```bash
# Create user-a
curl -s -u admin:admin -X POST \
  'http://localhost/alfresco/api/-default-/public/alfresco/versions/1/people' \
  -H 'Content-Type: application/json' \
  -d '{"id":"user-a","firstName":"User","lastName":"A","email":"user-a@test.local","password":"password"}'

# Create user-b
curl -s -u admin:admin -X POST \
  'http://localhost/alfresco/api/-default-/public/alfresco/versions/1/people' \
  -H 'Content-Type: application/json' \
  -d '{"id":"user-b","firstName":"User","lastName":"B","email":"user-b@test.local","password":"password"}'
```

**Nuxeo** -- via web UI at `http://localhost:8081/nuxeo` (Admin > Users & Groups) or REST:

```bash
curl -s -u Administrator:Administrator -X POST \
  'http://localhost:8081/nuxeo/api/v1/user' \
  -H 'Content-Type: application/json' \
  -d '{"entity-type":"user","id":"user-a","properties":{"password":"password","email":"user-a@test.local"}}'

curl -s -u Administrator:Administrator -X POST \
  'http://localhost:8081/nuxeo/api/v1/user' \
  -H 'Content-Type: application/json' \
  -d '{"entity-type":"user","id":"user-b","properties":{"password":"password","email":"user-b@test.local"}}'
```

### 0.3 Prepare test documents

Create the following files locally before running upload tests. The topics are intentionally
distinct so RAG relevance checks are unambiguous.

| File | Format | Size | Topic |
|---|---|---|---|
| `short-memo.txt` | Plain text | ~400 words | HR: remote work policy memo |
| `medium-policy.docx` | Word | ~8 pages | IT: information security policy |
| `long-report.pdf` | PDF | ~60 pages | Finance: annual performance report |
| `spreadsheet.xlsx` | Excel | 3 sheets | Finance: quarterly budget data |
| `presentation.pptx` | PowerPoint | 20 slides | Product: roadmap overview |
| `technical-spec.pdf` | PDF | ~15 pages | Engineering: REST API specification |

**`short-memo.txt` sample content** (create this file for the tests):

```
MEMORANDUM

To: All Staff
From: HR Department
Re: Updated Remote Work Policy

Effective immediately, all employees are eligible to work remotely up to three days per week
provided they maintain a dedicated workspace free from distractions...

[continue for ~400 words covering eligibility, equipment, connectivity requirements,
performance expectations, and manager approval process]
```

For the remaining formats, use any existing internal documents or generate representative
placeholder files with clearly distinct content per topic.

---

## A. Smoke Tests

Run these checks before any ingestion. All should pass within 60 seconds of stack startup.

### A1 -- Batch ingester health (Alfresco)

```bash
curl -s -u admin:admin http://localhost/api/sync/status | jq .
```

Expected: `200 OK` -- JSON object with a `jobs` array (may be empty) and queue metrics.

### A2 -- RAG service health

```bash
curl -s http://localhost/api/rag/health | jq .
curl -s http://localhost/api/rag/search/semantic/health | jq .
```

Expected: `200 OK` -- both responses show all subsystems as `UP` (embedding, hxpr, llm).

### A3 -- Alfresco repository connectivity

```bash
curl -s -u admin:admin \
  'http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/-root-/children' \
  | jq '.list.pagination'
```

Expected: `200 OK` -- pagination object with `totalItems > 0`.

### A4 -- Nuxeo connectivity *(full stack only)*

```bash
curl -s -u Administrator:Administrator \
  'http://localhost:8081/nuxeo/api/v1/path/default-domain' \
  -H 'Accept: application/json' | jq '.type'
```

Expected: `200 OK` -- `"Domain"`.

---

## B. Alfresco -- Batch Ingestion

### B1 -- Create test folder

```bash
FOLDER_ID=$(curl -s -u admin:admin -X POST \
  'http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/-my-/children' \
  -H 'Content-Type: application/json' \
  -d '{"name":"content-lake-test","nodeType":"cm:folder"}' \
  | jq -r '.entry.id')
echo "Test folder: $FOLDER_ID"
```

Expected: `201 Created` -- `$FOLDER_ID` is a UUID.

### B2 -- Upload test documents

Repeat for each document in the test corpus. Example for `short-memo.txt`:

```bash
TXT_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@short-memo.txt;type=text/plain" \
  -F 'name=short-memo.txt' \
  | jq -r '.entry.id')
echo "short-memo.txt node: $TXT_ID"
```

```bash
PDF_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@long-report.pdf;type=application/pdf" \
  -F 'name=long-report.pdf' \
  | jq -r '.entry.id')
echo "long-report.pdf node: $PDF_ID"
```

Record the `nodeId` for each document -- used in verification steps below.

Expected: `201 Created` for each upload.

### B3 -- Trigger Alfresco full sync

```bash
# In alfresco profile nginx routes /api/sync/* to batch-ingester:9090 automatically.
# No ?sourceType= parameter required.
JOB_ID=$(curl -s -u admin:admin -X POST \
  'http://localhost/api/sync/configured' \
  | jq -r '.jobId')
echo "Sync job: $JOB_ID"
```

Expected: `202 Accepted` -- response contains `jobId`.

### B4 -- Poll sync status until complete

```bash
# Poll every 10 seconds; stop when status is COMPLETED or FAILED
watch -n 10 "curl -s -u admin:admin http://localhost/api/sync/status/$JOB_ID | jq '{status,discoveredCount,processedCount,errorCount}'"
```

Expected: `status` transitions from `RUNNING` to `COMPLETED`;
`discoveredCount` and `processedCount` are both > 0.

### B5 -- Verify documents appear in semantic search

```bash
# HR document
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility policy","topK":5,"minScore":0.3}' \
  | jq '[.results[] | {nodeId: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Verify that `source_nodeId` in one of the top results matches `$TXT_ID`.

```bash
# Finance document
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"annual financial performance revenue","topK":5,"minScore":0.3}' \
  | jq '[.results[] | {nodeId: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Expected: `source_nodeId` matches `$PDF_ID`; `cin_ingestProperties.source_type` = `"alfresco"`.

### B6 -- Idempotency: re-run sync, verify no duplicate documents

```bash
# Trigger a second sync
curl -s -u admin:admin -X POST \
  'http://localhost/api/sync/configured' | jq .

# After COMPLETED, repeat the same search and count results
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility policy","topK":10,"minScore":0.3}' \
  | jq '.results | length'
```

Expected: result count is the same as after the first sync; no duplicates.

---

## C. Alfresco -- Live Ingestion

Allow ~5-15 seconds between each action and the verification search for ActiveMQ event
propagation and embedding to complete.

### C1 -- Create document event

```bash
NEW_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@technical-spec.pdf;type=application/pdf" \
  -F 'name=technical-spec.pdf' \
  | jq -r '.entry.id')
echo "Created: $NEW_ID"

# Wait for event propagation
sleep 15

# Verify it is searchable
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"REST API endpoint specification","topK":5,"minScore":0.3}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_nodeId == "'$NEW_ID'")]'
```

Expected: at least one result with `source_nodeId` = `$NEW_ID`.

### C2 -- Update document event

```bash
# Upload new version of the file (replace content)
curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$NEW_ID/content" \
  -H 'Content-Type: application/pdf' \
  --data-binary @technical-spec-v2.pdf | jq '.entry.modifiedAt'

sleep 15

# Search for a phrase unique to the new version
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase unique to v2>","topK":5,"minScore":0.3}' \
  | jq '[.results[] | {nodeId: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Expected: updated content is discoverable; old-content-only phrase returns reduced or zero score.

### C3 -- Delete document event

```bash
curl -s -u admin:admin -X DELETE \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$NEW_ID"

sleep 15

curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"REST API endpoint specification","topK":10,"minScore":0.1}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_nodeId == "'$NEW_ID'")]'
```

Expected: the array is empty -- deleted document no longer appears in any results.

### C4 -- Live ingester metrics

```bash
curl -s http://localhost:9092/api/live/status | jq .
```

Expected: `received`, `processed`, `filtered`, and `errors` counters are non-zero and
reflect the events triggered in C1-C3.

### C5 -- Permission change propagation

Grant `user-a` read access to a previously restricted document and verify the change
propagates to the search index (see also Section G for the full permission test suite).

```bash
# Set permissions on the HR memo: user-a READ, inherit off
curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$TXT_ID/permissions" \
  -H 'Content-Type: application/json' \
  -d '{
    "isInheritanceEnabled": false,
    "locallySet": [
      {"authorityId":"user-a","name":"Consumer","accessStatus":"ALLOWED"}
    ]
  }'

# Reconcile the ACL explicitly because Alfresco does not emit permission update events
curl -s -u admin:admin -X POST http://localhost/api/sync/permissions \
  -H 'Content-Type: application/json' \
  -d "{\"nodeIds\":[\"$TXT_ID\"],\"recursive\":true}" | jq .

sleep 5

# Search as user-a -- should now find the document
curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility policy","topK":5,"minScore":0.3}' \
  | jq '[.results[] | {nodeId: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Expected: result with `source_nodeId` = `$TXT_ID` now appears for `user-a`.

---

## D. Nuxeo -- Batch Ingestion

> Requires `make up-full` and the `nuxeo-deployment` stack running at `http://localhost:8081`.

### D1 -- Create test workspace

```bash
curl -s -u Administrator:Administrator -X POST \
  'http://localhost:8081/nuxeo/api/v1/path/default-domain/workspaces/' \
  -H 'Content-Type: application/json' \
  -d '{"entity-type":"document","type":"Workspace","name":"content-lake-test","properties":{"dc:title":"Content Lake Test"}}' \
  | jq '.uid'
```

Expected: `201 Created` -- returns document `uid`.

### D2 -- Upload test documents

Nuxeo uses a two-step upload (batch upload API) for binary content.

```bash
# Step 1: open upload batch
BATCH_ID=$(curl -s -u Administrator:Administrator -X POST \
  'http://localhost:8081/nuxeo/api/v1/upload' | jq -r '.batchId')

# Step 2: upload file
curl -s -u Administrator:Administrator -X POST \
  "http://localhost:8081/nuxeo/api/v1/upload/$BATCH_ID/0" \
  -H 'X-File-Name: short-memo.txt' \
  -H 'X-File-Type: text/plain' \
  -H 'Content-Type: text/plain' \
  --data-binary @short-memo.txt | jq .

# Step 3: attach to document
NUX_TXT_ID=$(curl -s -u Administrator:Administrator -X POST \
  'http://localhost:8081/nuxeo/api/v1/path/default-domain/workspaces/content-lake-test/' \
  -H 'Content-Type: application/json' \
  -d "{\"entity-type\":\"document\",\"type\":\"File\",\"name\":\"short-memo.txt\",
      \"properties\":{\"dc:title\":\"Short Memo\",\"file:content\":{\"upload-batch\":\"$BATCH_ID\",\"upload-fileId\":\"0\"}}}" \
  | jq -r '.uid')
echo "Nuxeo short-memo uid: $NUX_TXT_ID"
```

Repeat for each test document. Record the `uid` for each.

### D3 -- Trigger Nuxeo full sync

```bash
# In nuxeo profile nginx routes /api/sync/* to nuxeo-batch-ingester:9093 automatically.
# No ?sourceType= parameter required.
NUX_JOB=$(curl -s -u Administrator:Administrator -X POST \
  'http://localhost/api/sync/configured' | jq -r '.jobId')
echo "Nuxeo sync job: $NUX_JOB"
```

Expected: `202 Accepted`.

### D4 -- Poll sync status

```bash
watch -n 10 "curl -s -u Administrator:Administrator http://localhost/api/sync/status/$NUX_JOB \
  | jq '{status,discoveredCount,processedCount,errorCount}'"
```

Expected: `COMPLETED` with `processedCount > 0`.

### D5 -- Verify Nuxeo documents in semantic search

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility policy","topK":5,"minScore":0.3}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_type == "nuxeo") | {uid: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Expected: result with `source_nodeId` = `$NUX_TXT_ID` and `source_type` = `"nuxeo"`.

### D6 -- Idempotency re-run

Same procedure as B6, scoped to Nuxeo documents. Expected: no duplicate results after second sync.

---

## E. Nuxeo -- Live Ingestion

Nuxeo live sync uses audit log polling (default ~10-15 s interval). Allow 20-30 s for changes
to appear.

### E1 -- Create document (audit poll)

```bash
# Upload a new document directly (reuse batch upload pattern from D2)
# Record uid as $NUX_NEW_ID

sleep 25

curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<unique phrase from new document>","topK":5,"minScore":0.3}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_nodeId == "'$NUX_NEW_ID'")]'
```

Expected: document appears in results.

### E2 -- Update document

```bash
# Update document content via Nuxeo REST
curl -s -u Administrator:Administrator -X PUT \
  "http://localhost:8081/nuxeo/api/v1/id/$NUX_NEW_ID" \
  -H 'Content-Type: application/json' \
  -d '{"entity-type":"document","properties":{"dc:description":"Updated version with new content"}}' | jq .

sleep 25

# Search for updated metadata or content phrase
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from updated content>","topK":5,"minScore":0.3}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_nodeId == "'$NUX_NEW_ID'")]'
```

Expected: updated content is searchable.

### E3 -- Delete document

```bash
curl -s -u Administrator:Administrator -X DELETE \
  "http://localhost:8081/nuxeo/api/v1/id/$NUX_NEW_ID"

sleep 25

curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from deleted document>","topK":10,"minScore":0.1}' \
  | jq '[.results[] | select(.cin_ingestProperties.source_nodeId == "'$NUX_NEW_ID'")]'
```

Expected: empty array -- document removed from index.

---

## F. RAG Service

These tests assume the full corpus (Section B + D) is already indexed.

### F1 -- Semantic search: basic relevance

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"annual financial performance revenue","topK":5}' \
  | jq '[.results[] | {source: .cin_ingestProperties.source_nodeId, score: .score, text: (.sysembed_embeddings[0].text[:80])}]'
```

Expected: top results are from `long-report.pdf` and/or `spreadsheet.xlsx`; no HR or tech docs in top 3.

### F2 -- Semantic search: minScore filter

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"annual financial performance revenue","topK":10,"minScore":0.8}' \
  | jq '{count: (.results | length), sources: [.results[].cin_ingestProperties.source_nodeId]}'
```

Expected: fewer results than F1; all returned results have `score >= 0.8`; unrelated documents absent.

### F3 -- Hybrid search

```bash
curl -s -X POST http://localhost/api/rag/search/hybrid \
  -H 'Content-Type: application/json' \
  -d '{"query":"information security policy access control","topK":5}' \
  | jq '[.results[] | {source: .cin_ingestProperties.source_nodeId, score: .score}]'
```

Expected: `medium-policy.docx` ranks in the top 3; response includes fusion scores combining
vector and BM25 contributions.

### F4 -- RAG prompt (retrieval + LLM generation)

```bash
curl -s -X POST http://localhost/api/rag/prompt \
  -H 'Content-Type: application/json' \
  -d '{"query":"Summarise the key financial highlights from the annual report","topK":5}' \
  | jq '{answer: .answer, sourceCount: (.sources | length)}'
```

Expected: `200 OK` -- `answer` is a non-empty string with LLM-generated text;
`sources` references chunks from `long-report.pdf`.

### F5 -- Streaming chat (SSE)

```bash
curl -s -N -X POST http://localhost/api/rag/chat/stream \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d '{"query":"What are the main themes in the product roadmap?"}'
```

Expected: sequence of `data: {"token":"..."}` events ending with a `data: [DONE]` event;
reconstructed answer references content from `presentation.pptx`.

### F6 -- Cross-source search *(full stack only)*

```bash
# Upload identical-topic documents to both Alfresco and Nuxeo (e.g. two versions of the HR memo)
# Then query:
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility policy","topK":10,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_type] | unique'
```

Expected: array contains both `"alfresco"` and `"nuxeo"`.

---

## G. Permission Tests

Run after batch ingestion (Section B) has completed. Tests use documents uploaded with
specific ACLs.

For Alfresco sources, repository administrators remain discoverability-equivalent to
repository admins even when they are not explicitly present in `locallySet`. The examples
below therefore grant only the intended end-user or group ACEs.

### G1 -- Setup: upload permission-scoped documents

```bash
# confidential-hr.txt -- only user-a (Alfresco admins still see it)
HR_PRIV_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@short-memo.txt;type=text/plain" \
  -F 'name=confidential-hr.txt' | jq -r '.entry.id')

curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$HR_PRIV_ID/permissions" \
  -H 'Content-Type: application/json' \
  -d '{"isInheritanceEnabled":false,"locallySet":[
        {"authorityId":"user-a","name":"Consumer","accessStatus":"ALLOWED"}]}'

# tech-spec-internal.pdf -- only user-b (Alfresco admins still see it)
TECH_PRIV_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@technical-spec.pdf;type=application/pdf" \
  -F 'name=tech-spec-internal.pdf' | jq -r '.entry.id')

curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$TECH_PRIV_ID/permissions" \
  -H 'Content-Type: application/json' \
  -d '{"isInheritanceEnabled":false,"locallySet":[
        {"authorityId":"user-b","name":"Consumer","accessStatus":"ALLOWED"}]}'

# roadmap.pptx -- GROUP_EVERYONE (public)
PUBLIC_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -F "filedata=@presentation.pptx;type=application/vnd.openxmlformats-officedocument.presentationml.presentation" \
  -F 'name=roadmap.pptx' | jq -r '.entry.id')

curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$PUBLIC_ID/permissions" \
  -H 'Content-Type: application/json' \
  -d '{"isInheritanceEnabled":false,"locallySet":[
        {"authorityId":"GROUP_EVERYONE","name":"Consumer","accessStatus":"ALLOWED"}]}'
```

Call `/api/sync/permissions` for each changed node, or use a client flow that does it for you,
then verify all three are indexed as admin (G2 below).

### G2 -- Admin sees all documents

```bash
for QUERY in "remote work eligibility" "REST API endpoint" "product roadmap themes"; do
  echo "--- $QUERY ---"
  curl -s -u admin:admin -X POST http://localhost/api/rag/search/semantic \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$QUERY\",\"topK\":3,\"minScore\":0.3}" \
    | jq '[.results[] | {nodeId: .cin_ingestProperties.source_nodeId, score: .score}]'
done
```

Expected: each query returns at least one result; all three document node IDs (`$HR_PRIV_ID`,
`$TECH_PRIV_ID`, `$PUBLIC_ID`) appear across the three queries. This confirms that Alfresco
repository admins remain able to discover Alfresco documents even when the stored ACL only names
the end user or `GROUP_EVERYONE`.

### G3 -- user-a sees own documents + public

```bash
# Should find: confidential-hr.txt (own) and roadmap.pptx (public)
# Should NOT find: tech-spec-internal.pdf (user-b only)

curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: contains $HR_PRIV_ID

curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"product roadmap themes","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: contains $PUBLIC_ID

curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"REST API endpoint specification","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: does NOT contain $TECH_PRIV_ID
```

### G4 -- user-b sees own documents + public

```bash
# Should find: tech-spec-internal.pdf (own) and roadmap.pptx (public)
# Should NOT find: confidential-hr.txt (user-a only)

curl -s -u user-b:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"REST API endpoint specification","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: contains $TECH_PRIV_ID

curl -s -u user-b:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: does NOT contain $HR_PRIV_ID
```

### G5 -- Permission revocation propagates

```bash
# Remove user-a's access to confidential-hr.txt
curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$HR_PRIV_ID/permissions" \
  -H 'Content-Type: application/json' \
  -d '{"isInheritanceEnabled":false,"locallySet":[]}'

sleep 15

# user-a should no longer see it
curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"remote work eligibility","topK":5,"minScore":0.3}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
```

Expected: `$HR_PRIV_ID` is absent from user-a's results after revocation. An Alfresco admin can
still discover it because admin visibility is source-level rather than encoded as a synthetic ACE.

### G6 -- Folder ACL propagation to descendants

Validates that a folder-level permission change is propagated to all descendant files in hxpr
without re-ingesting content (issues #27 and #31).

Two child files cover the two propagation branches:

| File | `isInheritanceEnabled` | `locallySet` | Expected after folder restricted to user-a |
|---|---|---|---|
| `folder-child-inherit.txt` | `true` (default) | -- | Inherits folder ACL → user-a only |
| `folder-child-isolated.txt` | `false` | `user-b` | Keeps own ACL → user-b only |

#### G6.1 -- Setup: create folder and upload children

```bash
PERM_FOLDER_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLDER_ID/children" \
  -H 'Content-Type: application/json' \
  -d '{"name":"perm-propagation-test","nodeType":"cm:folder"}' \
  | jq -r '.entry.id')

# Child 1: no local ACL; will inherit from the folder
FOLD_CHILD_INHERIT_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$PERM_FOLDER_ID/children" \
  -F 'filedata=@folder-child-inherit.txt;type=text/plain' \
  -F 'name=folder-child-inherit.txt' | jq -r '.entry.id')

# Child 2: inheritance disabled; locally restricted to user-b only
FOLD_CHILD_ISOLATED_ID=$(curl -s -u admin:admin -X POST \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$PERM_FOLDER_ID/children" \
  -F 'filedata=@folder-child-isolated.txt;type=text/plain' \
  -F 'name=folder-child-isolated.txt' | jq -r '.entry.id')

curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$FOLD_CHILD_ISOLATED_ID" \
  -H 'Content-Type: application/json' \
  -d '{"permissions":{"isInheritanceEnabled":false,"locallySet":[
        {"authorityId":"user-b","name":"Consumer","accessStatus":"ALLOWED"}]}}'
```

#### G6.2 -- Ingest the subtree

```bash
curl -s -u admin:admin -X POST http://localhost/api/sync/batch \
  -H 'Content-Type: application/json' \
  -d "{\"folders\":[\"$PERM_FOLDER_ID\"],\"recursive\":true,\"types\":[\"cm:content\"]}"
# Wait for COMPLETED, then verify both files are visible as admin.
```

#### G6.3 -- Change folder permissions and reconcile

Disable inheritance on the folder and restrict to user-a only, then trigger a recursive ACL
reconciliation (no content re-ingestion):

```bash
curl -s -u admin:admin -X PUT \
  "http://localhost/alfresco/api/-default-/public/alfresco/versions/1/nodes/$PERM_FOLDER_ID" \
  -H 'Content-Type: application/json' \
  -d '{"permissions":{"isInheritanceEnabled":false,"locallySet":[
        {"authorityId":"user-a","name":"Consumer","accessStatus":"ALLOWED"}]}}'

curl -s -u admin:admin -X POST http://localhost/api/sync/permissions \
  -H 'Content-Type: application/json' \
  -d "{\"nodeIds\":[\"$PERM_FOLDER_ID\"],\"recursive\":true}"
```

#### G6.4 -- Verify propagation results

Expected after reconciliation:

```bash
# user-a FINDS folder-child-inherit.txt (inherited folder ACL)
curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"zephyr-indigo-kappa-fold inherited ACL propagation","topK":5,"minScore":0.2}' \
  | jq '[.results[] | .sourceDocument.nodeId]'
# Expected: contains $FOLD_CHILD_INHERIT_ID

# user-b CANNOT find folder-child-inherit.txt (removed from folder ACL)
curl -s -u user-b:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"zephyr-indigo-kappa-fold inherited ACL propagation","topK":5,"minScore":0.2}' \
  | jq '[.results[] | .sourceDocument.nodeId]'
# Expected: does NOT contain $FOLD_CHILD_INHERIT_ID

# user-b STILL finds folder-child-isolated.txt (own ACL unchanged)
curl -s -u user-b:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"zephyr-indigo-kappa-isol isolated ACL no-inherit propagation","topK":5,"minScore":0.2}' \
  | jq '[.results[] | .sourceDocument.nodeId]'
# Expected: contains $FOLD_CHILD_ISOLATED_ID

# user-a CANNOT find folder-child-isolated.txt (not in file's own locallySet)
curl -s -u user-a:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"zephyr-indigo-kappa-isol isolated ACL no-inherit propagation","topK":5,"minScore":0.2}' \
  | jq '[.results[] | .sourceDocument.nodeId]'
# Expected: does NOT contain $FOLD_CHILD_ISOLATED_ID

# Admin finds both files (source-level bypass, unaffected by any ACL)
```

### G7 -- Nuxeo permissions *(full stack only)*

Repeat the G1-G5 pattern using Nuxeo ACP APIs:

```bash
# Set ACL on a Nuxeo document to user-a only
curl -s -u Administrator:Administrator -X POST \
  "http://localhost:8081/nuxeo/api/v1/id/$NUX_TXT_ID/@op/Document.SetACE" \
  -H 'Content-Type: application/json' \
  -d '{"params":{"user":"user-a","permission":"Read","grant":true,"blockInheritance":true}}'
```

Expected behaviour: same as Alfresco permission tests -- Nuxeo ACP is mapped to `sys_acl`
in hxpr and enforced at search time.

---

## H. Chunking Strategy

These tests inspect the `sysembed_embeddings[].location` field in search results to verify
that the chunking pipeline produces accurate, well-bounded chunks across all supported formats.

### H1 -- Short document: single chunk

```bash
# short-memo.txt (~400 words) should produce exactly one embedding chunk
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d "{\"query\":\"remote work eligibility policy\",\"topK\":10,\"minScore\":0.1}" \
  | jq "[.results[] | select(.cin_ingestProperties.source_nodeId == \"$TXT_ID\") | .sysembed_embeddings | length]"
```

Expected: `[1]` -- a single embedding chunk covers the entire document.

### H2 -- Long PDF: page-specific chunk retrieval

```bash
# long-report.pdf (~60 pages) -- query phrases from different page ranges
# Page 1: executive summary
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from page 1 of long-report.pdf>","topK":3,"minScore":0.4}' \
  | jq '[.results[0].sysembed_embeddings[0].location]'
# Expected: location.page ≤ 2

# Page ~30: mid-report section
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from page 30 of long-report.pdf>","topK":3,"minScore":0.4}' \
  | jq '[.results[0].sysembed_embeddings[0].location]'
# Expected: location.page ≈ 28-32

# Page ~58: appendix
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from final pages of long-report.pdf>","topK":3,"minScore":0.4}' \
  | jq '[.results[0].sysembed_embeddings[0].location]'
# Expected: location.page ≥ 55
```

### H3 -- Multi-sheet spreadsheet

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<value or label unique to Sheet 2 of spreadsheet.xlsx>","topK":3,"minScore":0.3}' \
  | jq '[.results[0].sysembed_embeddings[0].location]'
```

Expected: `location.spreadsheet` field present and identifies the correct sheet; `location.page` absent or null.

### H4 -- Presentation slide-level chunks

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<phrase from slide 15 of presentation.pptx>","topK":3,"minScore":0.3}' \
  | jq '[.results[0].sysembed_embeddings[0].location]'
```

Expected: `location.page` (slide number) ≈ 14-16.

### H5 -- Code-heavy PDF: no mid-sentence splits

```bash
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"<API method or technical term from technical-spec.pdf>","topK":3,"minScore":0.3}' \
  | jq '[.results[0].sysembed_embeddings[0].text]'
```

Expected: the returned `text` field starts and ends on complete sentences (not mid-word or
mid-code-block splits). Check that the chunk does not begin with a lowercase letter that
implies a truncated sentence start.

### H6 -- Topic isolation

```bash
# Finance query → no HR or tech docs in top 3
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"quarterly revenue EBITDA operating margin","topK":3,"minScore":0.4}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: all IDs belong to financial documents (long-report.pdf, spreadsheet.xlsx)

# HR query → no finance or tech docs in top 3
curl -s -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query":"employee remote work days per week manager approval","topK":3,"minScore":0.4}' \
  | jq '[.results[] | .cin_ingestProperties.source_nodeId]'
# Expected: all IDs belong to HR documents (short-memo.txt, medium-policy.docx)
```

---

## Execution Order Summary

### Phase 1 -- alfresco profile
Start: `make up-alfresco`

| Order | Section | Prerequisite |
|---|---|---|
| 1 | A -- Smoke Tests | Stack healthy |
| 2 | B -- Alfresco Batch | A passes |
| 3 | C -- Alfresco Live | B completed |
| 4 | G -- Permission Tests | B completed; test users created |
| 5 | H -- Chunking Strategy | B completed |

Stop: `make down`

### Phase 2 -- nuxeo profile
Start: `(cd ../nuxeo-deployment && docker compose up -d)` then `make up-nuxeo`

| Order | Section | Prerequisite |
|---|---|---|
| 6 | A -- Smoke Tests (repeat) | Stack healthy |
| 7 | D -- Nuxeo Batch | A passes |
| 8 | E -- Nuxeo Live | D completed |

Stop: `make down` then `(cd ../nuxeo-deployment && docker compose down)`

### Phase 3 -- full profile (optional cross-source)
Start: `(cd ../nuxeo-deployment && docker compose up -d)` then `make up-full`

| Order | Section | Prerequisite |
|---|---|---|
| 9 | F -- RAG Service (F6 cross-source) | B + D indexing complete |

> The automated scripts in `test/run-tests.sh` execute Phases 1 and 2 in sequence.

Each test case result should be recorded as: **command → HTTP status → key response fields → PASS / FAIL**.
