# Deployment -- Alfresco Stack

> For first-run instructions, prerequisites, credentials, and Makefile commands see the
> [main README](../README.md). This page covers Alfresco-specific configuration only.

For Nuxeo-specific setup see [deployment-nuxeo.md](deployment-nuxeo.md).
For RAG service configuration see [deployment-rag.md](deployment-rag.md).

All commands run from `content-lake-app-deployment/`.

---

## Alfresco Requirements

The following Alfresco-side components are required for Content Lake to function:

- **`content-lake-repo-model` module** installed in Alfresco Repository so the `cl:indexed` and
  `cl:excludeFromLake` aspects exist. The same module contains the repository-side ACL
  reconciliation hook that publishes permission changes to a persistent ActiveMQ queue. The ACS
  image is built locally from `acs/alfresco/`.
- **ActiveMQ** configured for Alfresco Event2 so `live-ingester` can consume `alfresco.repo.event2`
- **Alfresco Transform Core AIO** for text extraction during ingestion
- **Alfresco repository search** on OpenSearch (the `elasticsearch` index subsystem), fed by the
  `batch-indexer` service -- see [Search: OpenSearch](#search-opensearch-alfresco-search-community)

---

## Search: OpenSearch (Alfresco Search Community)

As of ACS Community 26.2 the repository is indexed by the OpenSearch-based **Alfresco Search
Community** module instead of Solr. The repository search subsystem points at the same
`opensearch` cluster that hxpr uses (declared in `compose.hxpr.yaml`); the two run as independent
indices in one cluster with no cross-index reads:

| Index | Owner | Purpose |
|---|---|---|
| `alfresco*` (`alfresco`, `alfresco-reindex-state`, `alfresco-reindex-dead-letter`) | Alfresco repository | Metadata + content search (AFTS) |
| `nuxeo_embeddings*` | hxpr | Semantic / vector search |

Wiring in `compose.alfresco.yaml`:

- The `alfresco` repository runs with `-Dindex.subsystem.name=elasticsearch`,
  `-Delasticsearch.host=opensearch`, `-Delasticsearch.port=9200`,
  `-Delasticsearch.createIndexIfNotExists=true`, and keeps `-Dsolr.secureComms=secret`
  plus `-Dsolr.sharedSecret=${SHARED_SECRET}` (the repo-side transform secure-comms knobs).
- The `batch-indexer` service (`alfresco/alfresco-elasticsearch-batch-indexing`) runs in
  continuous-polling mode. The interval is tuned down to `2s`
  (`ALFRESCO_REINDEX_CONTINUOUS_POLLINGINTERVAL`, override with `SEARCH_INDEXER_POLLINGINTERVAL`)
  vs the 15s production default so new content is AFTS-searchable within a couple of seconds. Its
  `ALFRESCO_CONTENT_TRANSFORM_SHAREDSECRET` **must match** the repository's `solr.sharedSecret`
  -- both are set to `${SHARED_SECRET}`.
- The indexer resolves namespace URIs to prefixes from a static file, not from the repository
  dictionary, and the one bundled in the image lists only stock Alfresco namespaces. Custom models
  are dropped from the index with `impossible to get prefixed name of <property>` in the log, so
  `ALFRESCO_REINDEX_PREFIXES_FILE` points at `acs/search/reindex.prefixes-file.json`, which adds
  the `cl` prefix for the Content Lake model. **Add an entry there for every new custom model**, or
  its aspects and properties will be missing from `alfresco` while the nodes themselves are indexed
  -- AFTS then returns 0 hits for any query combining those fields with a non-transactional
  predicate (`ANCESTOR:`, `ID:`, facets), while a simple `ASPECT:"cl:indexed"` still looks correct
  because the repository answers it from the database.

This is a clean-deploy design: on a fresh stack the indexer starts at "now" and indexes content
created while it runs -- no migration or reindex-from-Solr, no cursor seeding. The archive/trashcan
search scope (`alfresco-archive`) is **not** implemented by the OpenSearch module.

> OpenSearch is pinned to `2.19.6` (`OPENSEARCH_TAG`), the version the hxpr reference stack uses
> (`Hyland/OpenArch`, `server/openarch-app/docker-compose.yml`). That is still
> a patch line above Alfresco's documented support matrix (OpenSearch 2.11.1 / ES 8.17.x) but within
> the same major version; production should pin a supported version or run separate clusters.
> Do not move this cluster to OpenSearch 3.x: 3.x enables `index.knn.derived_source` by default,
> which strips vectors from `_source` and reconstructs them from the HNSW `.vec` files at fetch
> time. After a segment merge those memory-mapped files can be `AlreadyClosed`, so hybrid
> (knn + text) search fails the fetch phase with "all shards failed" and RAG surfaces a 500.

Validate that both indices coexist once the stack is healthy:

```bash
docker compose exec opensearch curl -s http://localhost:9200/_cat/indices
# expect: alfresco, alfresco-reindex-state, alfresco-reindex-dead-letter, nuxeo_embeddings*
```

---

## ActiveMQ Credential Wiring (ACS 26.1.x)

With ACS `26.1.x`, the ActiveMQ broker credentials must be propagated to **three** distinct
places in `compose.alfresco.yaml`. Updating only the broker image is not enough:

| Component | Variable |
|---|---|
| `activemq` broker | `ACTIVEMQ_ADMIN_LOGIN` / `ACTIVEMQ_ADMIN_PASSWORD` |
| Alfresco Repository client | `messaging.broker.username` / `messaging.broker.password` |
| `transform-core-aio` client | `ACTIVEMQ_USER` / `ACTIVEMQ_PASSWORD` |

Leaving only the broker credentials set causes Repository or transform startup failures against
the authenticated broker.

These values are exposed as `ACTIVEMQ_USER` / `ACTIVEMQ_PASSWORD` in `.env` and propagated
automatically through `compose.alfresco.yaml`. Override them in `.env.local` if needed.

---

## Automatic ACL Reconciliation

When `CONTENT_LAKE_PERMISSION_SYNC_ENABLED=true` (the default), Alfresco Repository records
permission-affecting changes after commit and publishes a persistent ActiveMQ message to
`CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME`. `batch-ingester` consumes that queue and runs the
same ACL reconciliation logic exposed by `POST /api/sync/permissions`.

This is the **primary production path** for Alfresco ACL propagation because repository
permission updates are not reliably emitted as Event2 messages.

Changes caught by this flow:

- Alfresco UI permission edits
- Alfresco REST API permission changes
- Repository-side rules, scripts, or admin tools

| Variable | Default | Purpose |
|---|---|---|
| `CONTENT_LAKE_PERMISSION_SYNC_ENABLED` | `true` | Enable the repository-side ACL publisher |
| `CONTENT_LAKE_PERMISSION_SYNC_BROKER_URL` | `tcp://activemq:61616` | ActiveMQ broker for ACL messages |
| `CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME` | `contentlake.acl.changed` | Persistent queue consumed transactionally by `batch-ingester` |

This flow is eventually consistent. A permission revocation is visible to search only after the
repository module has published the queue message and `batch-ingester` has updated hxpr.

---

## Triggering a Sync

The proxy forwards the caller's own `Authorization` header to the ingester, which validates it
against its source repository. It supplies no credentials of its own, so each call needs credentials
valid in the repository behind the `?sourceType=` it routes to.

```bash
# Alfresco full sync
curl -u admin:admin -X POST 'http://localhost/api/sync/configured'

# Nuxeo full sync (full/demo profiles only)
curl -u Administrator:Administrator -X POST 'http://localhost/api/sync/configured?sourceType=nuxeo'
```

---

## Reconciling Deletions

A delete only reaches the index if a delete event reaches the live ingester. With the live ingester down,
a dropped broker message, or a node removed while only the batch ingester runs, the document outlives its
source and search returns it as a phantom result. Nothing sweeps for that on its own.

Each batch ingester can compare the index against what its discovery pass saw and delete the difference,
after a sync that completed cleanly. It is off by default in the application, because it deletes
documents. This stack turns it on with a raised ratio, since the demo corpus is small enough that the
default 0.10 trips on a single legitimate deletion:

| Variable | Default here | What it does |
|---|---|---|
| `INGESTION_RECONCILE_ENABLED` | `true` | Whether the sweep runs at all. The application default is `false` |
| `INGESTION_RECONCILE_MAX_DELETE_RATIO` | `0.5` | Largest fraction of in-scope documents one sweep may delete before aborting. The application default is `0.10` |
| `INGESTION_RECONCILE_MAX_DELETES` | `1000` | Absolute ceiling per sweep |
| `INGESTION_RECONCILE_MAX_SEEN_IDS` | `200000` | Bound on the node ids retained from discovery. Above it the sweep deletes nothing |
| `INGESTION_RECONCILE_PAGE_SIZE` | `200` | Documents per page when scanning the index |

The Nuxeo ingesters and the plugin runtime take the same five under `NUXEO_BATCH_RECONCILE_*` and
`CONNECTOR_BATCH_RECONCILE_*`.

Read the result off the job rather than inferring it from the index:

```bash
curl -u admin:admin "http://localhost/api/sync/status/<jobId>" | jq '.reconciliation'
```

Any `status` other than `COMPLETED` means nothing was deleted and names the reason. **The first sweep on
a corpus that has accumulated drift will abort on the ratio guard**, because a corpus with many genuinely
stale documents is indistinguishable from a broken discovery pass. That is the guard working: read the
logged figures, confirm the deletions are genuine, raise the ratio for one run, then lower it again.

A plugin connector has no live ingester, so there this sweep is the only path that ever deletes.

---

## Deploying to AWS EC2

See [DEPLOY_EC2.md](DEPLOY_EC2.md) for a step-by-step guide to running the full stack on a
`g5.2xlarge` Ubuntu instance with GPU-accelerated inference.
