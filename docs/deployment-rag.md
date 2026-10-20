# Deployment -- RAG Service

The `rag-service` Spring Boot app provides semantic search, hybrid search, and RAG (Retrieval-
Augmented Generation) over content indexed by the Content Lake ingesters.

---

## What It Does

- **Semantic search** -- kNN vector search against hxpr embeddings
- **Hybrid search** -- combines kNN with BM25 keyword search using Reciprocal Rank Fusion (RRF)
- **RAG prompt** -- retrieves context chunks and sends them with the user query to the configured LLM
- **Streaming RAG** -- same as RAG prompt but streams the LLM response via SSE
- **Conversation memory** -- maintains session state for multi-turn conversations

The service is nearly source-agnostic: it queries hxpr directly and uses `source_type` from
`cin_ingestProperties` to construct source-specific "open document" links (Alfresco Share URL vs.
Nuxeo Web UI URL).

---

## Dependencies

- `content-lake-core` (hxpr client, data model, chunking)
- `content-lake-spi` (SPI interfaces)
- hxpr platform (MongoDB + OpenSearch + embedding API)
- LLM inference backend (Docker Model Runner by default)

---

## Configuration

```yaml
hxpr:
  url: http://hxpr-app:8080
  repository-id: default
  username: admin      # engine HTTP Basic auth (filestore user store)
  password: password

spring:
  ai:
    openai:
      base-url: http://model-runner.docker.internal  # Docker Model Runner
      api-key: ignored                               # required by Spring AI client but unused
      embedding:
        model: ai/mxbai-embed-large
      chat:
        model: local/olmo3-7b-instruct:Q4_K_M

search:
  hybrid:
    enabled: true
    strategy: rrf          # rrf or weighted
    vector-weight: 0.7
    text-weight: 0.3
    initial-candidates: 75
    final-results: 20

rag:
  default-top-k: 15
  default-min-score: 0.01
  max-context-length: 20000
  reranker:
    enabled: false         # enable when a reranker endpoint is available
  prompt-injection:        # defend against injected instructions in retrieved content
    defense-enabled: false # wrap chunks as untrusted data + reinforce in the prompt
    scan-enabled: false    # log chunks matching known injection patterns (does not drop them)
  rate-limit:              # per-principal request throttling
    enabled: false
    generate-requests-per-minute: 20   # /api/rag/prompt, /api/rag/chat/stream
    search-requests-per-minute: 60     # /api/rag/search/**
  agentic-tools:           # let the LLM call retrieval tools mid-answer
    enabled: false
    max-iterations: 2      # additional retrieval rounds allowed per request
  mcp:
    enabled: true          # expose the MCP server (behind the same auth chain)
  embedding:               # querying a corpus that holds more than one embedding type
    additional-models: []  # models besides the configured one whose vectors are still present
    type-discovery:
      enabled: true        # read the types present from the index rather than assuming
      ttl-seconds: 300
    backfill:              # re-embed the corpus into the configured type
      enabled: false
      docs-per-minute: 60
      operator-users: []   # accounts allowed to start, pause and resume it
```

The prompt-injection, rate-limit, and agentic-tools features default to **off** so the retrieval and
generation baseline is unchanged; enable them per deployment. The MCP server defaults to **on** but is
never anonymously reachable (see below).

On Linux, override `MODEL_RUNNER_URL` (set as `spring.ai.openai.base-url`) to
`http://host.docker.internal:12434` in `.env.local`.

---

## Authentication

All `/api/rag/**` endpoints except `/api/rag/health` require **HTTP Basic Auth**. Credentials are
validated against the configured content source(s):

1. **Alfresco** -- via `POST .../authentication/versions/1/tickets` (tried first)
2. **Nuxeo** -- via `GET .../api/v1/me` (tried if Alfresco is unreachable or unconfigured)

The authenticated username is then used to resolve the caller's group memberships (via the service
account) and build the `sys_racl` permission filter passed to hxpr. This ensures search results are
scoped to documents the caller is actually allowed to read.

That filter is built by a single class, `AclFilterBuilder` in `content-lake-core`, which both the
semantic and the hybrid search path call. rag-service connects to hxpr as one administrator service
account, so hxpr applies no ACL filter of its own and this predicate is the only thing scoping
results: the hxpr port must therefore never be reachable by end users or agents, who would otherwise
query it directly with no filter at all. When no permission source can be resolved for a caller the
predicate matches nothing rather than everything.

### Which sources the filter covers

A clause is built per source, so a source nothing names contributes no clause and none of its
documents can be matched. The set of sources is discovered from the index: one terms aggregation over
`cin_sourceId`, whose values are the stored `<sourceType>:<sourceId>` pairs, refreshed every 30 seconds.
A source ingested into after rag-service started therefore becomes searchable without a restart, within
that window, which is what a connector jar dropped into a running deployment needs.

Two consequences worth knowing before deploying a source other than Alfresco or Nuxeo, which today
means any plugin connector on `plugin-batch-ingester`:

- **Group memberships can only be expanded for a source type that has a resolver.** rag-service holds
  one group resolver per source type, selected by the `<sourceType>` half of `cin_sourceId`; it ships
  `alfresco` and `nuxeo`. A source of any other type gets a clause built from the caller's own
  authorities: documents carrying `__Everyone__` and documents granted to the caller by name are
  retrievable, and documents granted to a *group* are not. That is deliberate, because the alternative
  is over-sharing, and it is logged once per source at WARN. Making a group-based source retrievable is
  a code change, but a bounded one: one new bean declaring its `sourceType()`, with nothing to alter in
  the search paths.
- **A principal with no object in the directory is not the same as an outage.** A resolver that reaches
  its directory and finds no such identity leaves the caller their default authorities on that source,
  which is what a site-local or repository-local principal needs; only a directory that could not be
  asked at all follows `RAG_SECURITY_GROUP_RESOLUTION_FAILURE`.
- **`RAG_PERMISSION_SOURCE_IDS` disables discovery entirely.** Pinning it was the only way to make a
  third source retrievable before this behaviour existed, and a pin that omits a source hides that
  source's documents. Leave it unset unless the set must not be inferred; when it is set, rag-service
  logs at startup which indexed sources the pin fails to cover.

Neither input to that filter has a permissive fallback. A request that reaches a search endpoint with
no authenticated principal is rejected with 401 rather than answered under a placeholder name, and a
source whose group directory is unreachable is handled according to
`RAG_SECURITY_GROUP_RESOLUTION_FAILURE` (described with the other environment flags below). The worst outcome of
either failure is a caller seeing fewer documents than they should, together with a WARN in the
rag-service log.

Only three paths are public: `/api/rag/health`, `/actuator/health` and `/actuator/info`. Every other
path, `/actuator/metrics` included, requires credentials. Adding a route
takes no security configuration to protect it; the chain denies by default, so a new endpoint is
authenticated unless it is deliberately exempted.

### Unauthenticated requests

Requests without a valid `Authorization: Basic ...` header receive **HTTP 401**.

```bash
# Correct -- with credentials
curl -u admin:admin -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "retention policy", "topK": 5}'

# Rejected -- no credentials → 401
curl -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "retention policy", "topK": 5}'
```

---

## REST API

All endpoints are under `/api/rag/` (proxied through nginx). Include Basic Auth on every request
(see [Authentication](#authentication) above).

### Semantic search

```http
POST /api/rag/search/semantic
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "query": "document retention policy",
  "topK": 5,
  "minScore": 0.7
}
```

### Hybrid search

```http
POST /api/rag/search/hybrid
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "query": "document retention policy",
  "maxResults": 5
}
```

### Choosing topK or topDocuments

Both search endpoints accept two budgets, and which one to send depends on what the caller counts.

`topK` (`maxResults` on hybrid search) is a budget of **chunks**. A document contributes every chunk it has
to the ranking, so a single long document can fill the budget on its own: on the deployment corpus a `topK`
of 10 has returned 10 chunks belonging to 2 documents. That is what you want for feeding a context window,
where the unit of value is a passage.

`topDocuments`, with the optional `chunksPerDocument`, is a budget of **documents**. Send it when the caller
is a person or a UI browsing results, where "ten results" means ten files. When present it replaces `topK` /
`maxResults` entirely rather than combining with them.

```http
POST /api/rag/search/semantic

{
  "query": "document retention policy",
  "topDocuments": 10,
  "chunksPerDocument": 2
}
```

Three things worth knowing before turning it on:

- The answer can be shorter than `topDocuments * chunksPerDocument`. A document outside the budget is never
  admitted to fill the remainder, so a corpus with fewer matching documents than asked for returns fewer.
  Read `documentCount` rather than counting `results`.
- It costs retrieval depth. Satisfying a document budget means asking the index for more rows than the answer
  carries, and the semantic endpoint may re-query at a doubled depth up to twice more when the candidate pool
  turns out to be dominated by a few documents. Expect higher latency on a skewed corpus than the same
  request expressed in chunks.
- Both fields are per-request. The deployment-wide equivalent is
  `rag.retrieval.document-diversity.max-chunks-per-document` (default 2), which bounds any one document's
  share of a `topK` answer and is the fallback when `topDocuments` arrives without `chunksPerDocument`.

Zero or negative values are rejected with 400. Values over the maximum (50 documents, 10 chunks per document)
are clamped, and the response reports what was applied in `appliedTopDocuments` and
`appliedChunksPerDocument`.

### RAG prompt

```http
POST /api/rag/prompt
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "question": "What is our document retention policy?",
  "topK": 5,
  "responseFormat": "STRUCTURED"
}
```

`responseFormat` (default `TEXT`) is optional. When set to `STRUCTURED`, the response includes an
additional `structured` object (`{summary, keyPoints[], citations[]}`) derived from the answer in a
second pass; the free-text `answer` field is always present and unchanged, so existing callers are
unaffected.

### Streaming RAG (SSE)

```http
POST /api/rag/chat/stream
Authorization: Basic <base64(user:password)>
Content-Type: application/json
Accept: text/event-stream

{
  "sessionId": "optional-session-id",
  "question": "What is our document retention policy?"
}
```

Event sequence: `token` per delta, then `metadata` with the full response (sources, timings,
`requestId`), then `done`. With `"responseFormat": "STRUCTURED"` a `structured` event carrying the
typed answer arrives between `metadata` and `done`, rather than inside `metadata`: deriving it is a
second LLM pass over the finished answer, so sending it inline would leave the client holding a
complete answer with no sources for the length of that call. Clients should render on `metadata` and
fill the structured block when the later event lands. The non-streaming `/api/rag/prompt` still
returns `structured` inside its single response.

### Feedback (answer rating)

```http
POST /api/rag/feedback
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "requestId": "the requestId echoed by /api/rag/prompt",
  "rating": "down",
  "comment": "optional note",
  "question": "the original question (echoed for corpus building)",
  "answer": "the rated answer (optional)",
  "sourceNodeIds": ["node-a", "node-b"]
}
```

Persists a rating for a generated answer as an hxpr document under `RAG_FEEDBACK_BASE_PATH`
(default `/_feedback`), returning `{ "stored": true, "feedbackId": "..." }`. Every `/api/rag/prompt`
and streaming `metadata` response carries a `requestId` used to correlate the feedback with the
answer. `GET /api/rag/feedback?rating=down&limit=200` lists stored feedback for the offline
evaluation harness (`cleval feedback import`). Enabled by default; set `RAG_FEEDBACK_ENABLED=false`
to disable the endpoint. Both verbs require authentication like the other `/api/rag/**` endpoints.

### Evaluation smoke check (opt-in)

```http
POST /api/rag/evaluate
Authorization: Basic <base64(user:password)>
Content-Type: application/json

[
  {"question": "...", "expectedAnswer": "...", "expectedSourceIds": ["policy.txt"]}
]
```

Runs a small caller-supplied sample set through the pipeline and returns coarse retrieval-hit and
faithfulness signals. Disabled unless `RAG_EVALUATION_ENABLED=true`. This is a quick in-cluster sanity
check, not the quality gate: the `content-lake-eval` harness (`cleval run` / `cleval compare`) remains
the authoritative RAGAS-style measurement.

`compose.content-lake.yaml` exposes the rag-service retrieval and generation knobs as environment
variables, all **default off**, so the baseline pipeline is unchanged unless a flag is set:

- Re-ranking and diversification: `RAG_RERANKER_ENABLED` (`RAG_RERANKER_URL`, `RAG_RERANKER_TOP_N`),
  `RAG_MMR_ENABLED` (`RAG_MMR_LAMBDA`, `RAG_MMR_POOL_SIZE`).
- Query expansion and self-RAG: `RAG_MULTI_QUERY_ENABLED`, `RAG_HYDE_ENABLED`,
  `RAG_QUERY_DECOMPOSITION_ENABLED`, and the relevance gate `RAG_RETRIEVAL_GRADING_ENABLED`.
- Context and generation: `RAG_RETRIEVAL_SMALL_TO_BIG_ENABLED` (expand a hit to its parent section),
  `RAG_CITATION_VERIFY_ENABLED` (flag answer claims unsupported by the cited context, adding
  `verified` / `unsupportedClaims` to the prompt response), `RAG_CONVERSATION_SUMMARY_ENABLED`
  (persistent running summary under the hxpr `_sessions/` folder), and per-request `inferFilters` on
  `/api/rag/prompt` (LLM-inferred date/mime/path filters).
- Semantic query caching: `RAG_CACHE_ENABLED` (default off) turns on a bounded, short-TTL in-memory
  cache of query embeddings and full retrieval results (`RAG_CACHE_TTL_SECONDS` default 60,
  `RAG_CACHE_MAX_SIZE` default 1000). Result-cache entries are scoped by the authenticated principal,
  so a cached answer is never served across ACL contexts; the TTL bounds how stale a principal's
  group membership may be. Hit-rate is exposed as `cache.gets{cache=rag.query.results}` /
  `{cache=rag.query.embeddings}` under `/actuator/metrics`.
- Group-resolution failure policy: `RAG_SECURITY_GROUP_RESOLUTION_FAILURE` (default `fail-closed`)
  decides what a query does when the caller's group membership cannot be read from a source
  repository. `fail-closed` excludes that source from the permission filter, so a directory outage
  narrows results; `degrade` proceeds with the caller's own name plus `GROUP_EVERYONE`, losing only
  group-granted documents. Both log at WARN, and an unrecognised value is read as `fail-closed`.
- Group membership caching: `RAG_SECURITY_GROUP_CACHE_TTL_SECONDS` (default 300) and
  `RAG_SECURITY_GROUP_CACHE_MAX_SIZE` (default 10000) bound an in-memory cache of resolved group
  memberships, keyed by source type and username, so a query does not pay a directory round trip per
  source. The TTL is the ceiling on how stale a caller's membership may be, so a deployment that
  revokes group access and expects it to take effect immediately should lower it; `0` disables the
  cache and asks the directory on every query. A directory failure is never cached, so an outage is
  retried rather than held for the TTL. Hit-rate is exposed as `cache.gets{cache=rag.security.groups}`
  under `/actuator/metrics`.
- Administrator bypass: `RAG_SECURITY_ADMIN_BYPASS_ENABLED` decides whether a member of
  `GROUP_ALFRESCO_ADMINISTRATORS` reads an Alfresco source with no `sys_racl` condition at all. The
  application default is `false`, so an administrator is filtered by document ACLs like anyone else.
  This stack sets it to `true`, because `admin:admin` is its working account and repository-admin
  discoverability is part of what it demonstrates; set it to `false` for a deployment where
  administrators must not see documents their own ACLs exclude. The bypass never applies to a Nuxeo
  source, whatever this flag says.
- User feedback capture: `RAG_FEEDBACK_ENABLED` (default **on**) exposes `POST/GET /api/rag/feedback`;
  `RAG_FEEDBACK_BASE_PATH` (default `/_feedback`) is the hxpr folder feedback is stored under.
  `GET /api/rag/feedback` returns only the calling account's own ratings, since an entry holds a user's
  question and the answer they were given. `?scope=all` returns every submitter's and is restricted to
  the accounts in `RAG_FEEDBACK_OPERATOR_USERS` (comma-separated, empty in the application default,
  `admin,Administrator` in this stack); anyone else gets 403. `cleval feedback import` uses that view,
  so the credentials it runs with must appear in the list.
- Named-query discovery: `RAG_NAMEDQUERY_DISCOVERY_ENABLED` (default **on**) controls whether
  `GET /api/rag/named-queries` lists the named queries registered in hxpr. The UI turns that list
  into a "Saved query" selector and hides the selector when the list is empty, so set it to `false`
  where hxpr only has its own internals registered (`tree_children`, `simple_search`,
  `folder_listing`, ...) and there is nothing curated to offer. Discovery only: a `namedQuery` a
  client names explicitly on a search request is still applied.

### Health check (public)

```http
GET /api/rag/health
```

### Operational status (authenticated)

```http
GET /api/status
Authorization: Basic <base64(user:password)>
```

Returns hxpr connectivity, per-source indexed document counts (`cin_sourceId` -> count), and
embedding/model-runner reachability in one snapshot. Authenticated, since per-source counts are
information disclosure. Custom `hxpr` and `modelRunner` health contributors also appear under
`/actuator/health` (component details shown to authenticated callers).

The batch ingesters (`alfresco-batch-ingester`, `nuxeo-batch-ingester`, `plugin-batch-ingester`)
each expose their own `GET /api/status` with the last run's timestamp and discovered / indexed /
failed counts; the detailed per-job view remains at `GET /api/sync/status`.

### Embedding backfill (opt-in, operator only, reachable only inside the stack network)

Present only when `RAG_EMBEDDING_BACKFILL_ENABLED=true`.

```http
POST /api/admin/embedding-backfill/start?docsPerMinute=60
POST /api/admin/embedding-backfill/pause
POST /api/admin/embedding-backfill/resume
GET  /api/admin/embedding-backfill/status
```

**These paths are not published by the proxy.** `nginx.conf.template` routes `/api/rag`, `/api/sync`,
`/api/content-lake`, `/api/status`, `/mcp` and `/admin`, and there is no `/api/admin`, so a request to
`https://<host>/api/admin/embedding-backfill/status` falls through to the UI and returns a redirect
rather than reaching `rag-service`. That is deliberate: a backfill is run by whoever operates the
deployment, who already has container access, and publishing an admin path would widen what is reachable
from outside the cluster for every deployment that turns the feature on. `rag-service` publishes no host
port either, so drive the endpoints from inside the `stack` network:

```bash
docker run --rm --network content-lake-app_stack curlimages/curl:latest \
  -s -u admin:<password> -X POST \
  "http://rag-service:9091/api/admin/embedding-backfill/start?docsPerMinute=60"
```

Re-embeds every indexed document into the currently configured embedding type, leaving other types in
place so they keep answering queries until the run finishes. The three state-changing calls require an
account named in `RAG_EMBEDDING_BACKFILL_OPERATOR_USERS`; anyone else gets 403, because the job writes
to the whole corpus and spends the embedding throughput the ingesters need. `status` is readable by any
authenticated caller and reports the target type plus counts of documents scanned, backfilled, skipped
(already carrying the target type, or holding no extracted text) and failed.

`scanned` counts a document once per scan pass, and `resume` restarts its scan from the beginning, so a
run that was paused reports a `scanned` larger than the corpus. The other counters are not affected.

To move a corpus onto a new embedding model without search degrading:

1. add the current model to `RAG_EMBEDDING_ADDITIONAL_MODELS` and set `EMBEDDING_MODEL` to the new one,
   then restart `rag-service` and the ingesters. Both types are now queried, each in its own space.
2. start the backfill and watch `status` until it reports `COMPLETED`.
3. remove the old model from `RAG_EMBEDDING_ADDITIONAL_MODELS`.

Coexisting types must share vector dimensionality, and therefore the same index field and similarity
metric. That is a property of the embeddings index rather than of this configuration, and it is what
makes scores from different types directly comparable: they are merged as hxpr reported them, with no
per-type rescaling, so `SEARCH_HYBRID_MIN_SCORE` and `RAG_RETRIEVAL_GRADING_MIN_SCORE` keep their meaning
while more than one type is live.

`type-discovery` reads the types present from `sysembed_type` on the embedding rows. There is no
aggregation endpoint over the embeddings index, so it scans pages of rows and stops at a ceiling, which
makes it a sample on a large corpus: a type holding a very small share of one can go unnoticed, and an
undiscovered type is not queried. The log says which happened, either `Corpus holds N embedding types ...
the whole index` or a line reporting that discovery stopped at its ceiling. Name the models in
`additional-models` if you need the set pinned rather than inferred.

Documents reported as `skippedNoText` hold no extracted-text mirror and need a full re-sync rather than
a backfill. The job deliberately does not update the content fingerprint, so the next content sync
re-chunks and re-embeds each backfilled document from its source.

---

## Rate Limiting

When `rag.rate-limit.enabled=true`, a per-authenticated-principal token bucket throttles requests.
Generation endpoints (`/api/rag/prompt`, `/api/rag/chat/stream`) get a
tighter budget (`generate-requests-per-minute`, default 20) than search (`/api/rag/search/**`,
`search-requests-per-minute`, default 60). Exceeding the budget returns **HTTP 429** with a
`Retry-After` header. Buckets are in-memory and therefore per-instance; a multi-instance deployment
does not share limits.

---

## Agentic Tool-Calling

When `rag.agentic-tools.enabled=true`, the RAG model may invoke a small toolset mid-answer
(`researchAgain`, `getDocument`, `listSources`) to fetch more evidence when the initial context is
insufficient, bounded by `max-iterations` (default 2). Every tool-invoked retrieval is ACL-scoped to
the request principal - identity comes from the authenticated request, never from a tool argument -
so tools cannot widen the caller's access. Off by default.

---

## Prompt-Injection Defense

Retrieved document content is untrusted: a stored document can contain text like "ignore previous
instructions". Two independent, default-off guards address this:

- `rag.prompt-injection.defense-enabled` wraps each retrieved chunk in explicit "untrusted document
  data, not instructions" delimiters and reinforces that framing in the prompt.
- `rag.prompt-injection.scan-enabled` runs a heuristic scanner over each chunk and logs matches for
  audit. Flagged chunks are **not** dropped (they may hold evidence the user needs).

Both default off so the generation baseline is unchanged; enable and re-measure with
`content-lake-eval` before turning them on in production.

---

## MCP Server

When `rag.mcp.enabled=true` (default), rag-service publishes a Model Context Protocol server
exposing `secureSearch`, `getDocument`, and `listSources` tools to external LLM agents. The transport
is synchronous WebMVC and sits behind the same `SecurityFilterChain` as the REST API, so it is
reachable only with HTTP Basic or Alfresco-ticket credentials (compatible with the official Alfresco
MCP Server client model) and never anonymously. Tools derive the ACL identity from the authenticated
request, so an agent cannot query as another user. Set `RAG_MCP_ENABLED=false` to disable.

---

## Security

`RagSecurityConfig` enforces HTTP Basic Auth for all search and prompt endpoints. The
`MultiSourceAuthenticationProvider` validates incoming credentials by calling the upstream
repository (Alfresco tickets API, then Nuxeo `/me`) with a 3 s connect timeout. Connection
failures are treated as "source unavailable" and the next source is tried; if all sources fail
or reject the credentials, a `401 Unauthorized` is returned.

The service account credentials (`ALFRESCO_INTERNAL_USERNAME` / `ALFRESCO_INTERNAL_PASSWORD`,
`NUXEO_USERNAME` / `NUXEO_PASSWORD`) are used only for internal operations (group membership
lookups, metadata enrichment) -- they are never used to validate incoming requests.

[`docs/security-model.md`](https://github.com/AlfrescoLabs/content-lake-app/blob/main/docs/security-model.md)
in `content-lake-app` is the full picture: which component enforces read access and why, what the model
explicitly does not do, and a hardening checklist for a deployment reachable by anyone other than you.

---

## Multi-Source Results

When results come from both Alfresco and Nuxeo, `SourceMetadataResolver` builds the "open in
source" link using `source_type` from `cin_ingestProperties`:

- `alfresco` → Alfresco Share URL: `{alfrescoBaseUrl}/share/page/document-details?nodeRef=workspace://...`
- `nuxeo` → Nuxeo Web UI URL: `{nuxeoBaseUrl}/nuxeo/ui/#!/doc/{uid}`

Permission filtering (`sys_racl`) works at the hxpr level and is already multi-source aware.

---

## Conversation Memory

The `ConversationMemoryService` maintains session state in `InMemoryConversationMemoryStore`.
Sessions are keyed by `sessionId` (UUID). Each session stores a list of `ConversationTurn` (user
query + assistant response).

For production, replace `InMemoryConversationMemoryStore` with a Redis or database-backed
implementation if multiple rag-service instances or pod restarts are expected.

---

## Observability

Health: `/actuator/health` (public, no auth required, so the container orchestrator can probe it).
Info: `/actuator/info` (public).

Metrics come from Micrometer at `/actuator/metrics`, which requires credentials: it enumerates the
service's endpoints and reveals request volumes and timings. A scraper needs an account valid in one of
the configured content sources, the same as any other caller:

```bash
curl -u admin:admin http://localhost/actuator/metrics
```

There is no `/actuator/prometheus`. No Prometheus registry is on the classpath and `prometheus` is not
in `management.endpoints.web.exposure.include`, so exporting metrics in that format means adding
`micrometer-registry-prometheus` and publishing one more authenticated endpoint. Traces, described
below, carry the RAG payloads; metrics export is a separate decision.

### Distributed tracing

The pipeline is instrumented with Micrometer Tracing (OpenTelemetry bridge). One request produces one
trace:

```
rag.request                     the whole RAG request
  rag.retrieve                  retrieve, diversify, rerank, grade
    rag.embed.query             the query embedding call
    rag.search.vector           the hxpr vector query
    rag.search.keyword          the hxpr keyword query (hybrid only)
  rag.augment                   section expansion and context assembly
  rag.generate                  the LLM call
```

Spring AI contributes its own advisor and model spans in between, so `rag.retrieve` and the rest are
descendants of `rag.request` rather than its direct children. On the streaming path the HTTP server
span closes when the `SseEmitter` is returned, before generation finishes, so `rag.request` outlives it
-- legal in OpenTelemetry, and it looks like a detached root in some trace UIs.

Trace and span ids reach every log line via the MDC (`[rag-service,<traceId>,<spanId>]`).

- `MANAGEMENT_TRACING_SAMPLING_PROBABILITY` -- sampling rate (default `0.1`; set `1.0` in dev). This is
  the only sampling knob; `RAG_OBSERVABILITY_*` deliberately does not add a second one.
- `MANAGEMENT_OTLP_TRACING_ENDPOINT` -- OTLP `/v1/traces` collector URL. **Blank by default**, so spans
  are created and logged but nothing is exported and no collector is required.

### Span payloads

Spans carry no payload unless asked. `RAG_OBSERVABILITY_PAYLOADS_ENABLED=true` attaches, per request:
the retrieved chunk ids, their document ids, scores and ranks; hit, candidate and pass counts; the
grading verdict; context and prompt sizes; token usage with its provenance
(`rag.tokens.total.source` is `usage`, `estimated` or `unavailable`, because a local backend often
reports none); the model; and which retrieval features configuration has enabled, as one
`rag.features` tag.

Note what "off by default" means here. With actuator on the classpath the `ObservationRegistry` is
never a no-op, so the spans exist on every request whatever this flag says. What the flag governs is
whether each one pays an O(hits) payload build, which is wasted work when nothing is exported. Turn it
on together with `MANAGEMENT_OTLP_TRACING_ENDPOINT`.

`RAG_OBSERVABILITY_CAPTURE_CONTENT=true` additionally attaches the question, its reformulated variant,
the retrieved chunk text, those documents' names and paths, and the answer. **That is ACL-protected
content leaving the service**, and a trace backend applies its own access model rather than the
documents' ACLs. Read the "Trace payloads are not ACL-filtered" section of the app repository's
`docs/security-model.md` before enabling it. `RAG_OBSERVABILITY_MAX_CONTENT_CHARS` (default 2000)
truncates each captured value and `RAG_OBSERVABILITY_MAX_CHUNKS_RECORDED` (default 20) bounds the
per-hit lists, so an enabled deployment cannot ship a whole context block per span.

### A local trace backend

The `observability` profile adds a single container bundling an OTLP collector, Prometheus, Tempo and a
pre-provisioned Grafana:

```bash
MANAGEMENT_OTLP_TRACING_ENDPOINT=http://otel-lgtm:4318/v1/traces \
MANAGEMENT_TRACING_SAMPLING_PROBABILITY=1.0 \
RAG_OBSERVABILITY_PAYLOADS_ENABLED=true \
  docker compose --profile demo --profile observability up -d
# Grafana on http://localhost:3001, Explore -> Tempo
```

It is a development and eval backend: Grafana runs with anonymous admin access. A real deployment
points the endpoint at its own collector and does not use this profile. `make down` and `make clean`
tear it down with everything else, and `make verify-profiles` asserts it never leaks into a base
profile.

### Cache metrics

When `RAG_CACHE_ENABLED=true`, the two Caffeine caches are bound to Micrometer and visible under
`/actuator/metrics`: `cache.gets{cache=rag.query.results,result=hit|miss}` and
`cache.gets{cache=rag.query.embeddings,...}`, plus `cache.size` / `cache.evictions`.
