# Content Lake App Deployment

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docs.docker.com/compose/)
[![Status](https://img.shields.io/badge/Status-PoC-yellow.svg)]()

Self-contained deployment for Content Lake App -- ingests content from Alfresco and Nuxeo into hxpr for hybrid semantic search and RAG.

## Content Lake Ecosystem

Part of the **Content Lake** ecosystem -- a PoC for ingesting Alfresco and Nuxeo content into the [ai-ready-index](https://github.com/Hyland/ai-ready-index) engine for hybrid semantic search and RAG.

| Repo | Role |
|---|---|
| [content-lake-app](https://github.com/AlfrescoLabs/content-lake-app) | Java ingestion pipeline and RAG service |
| **[content-lake-app-deployment](https://github.com/AlfrescoLabs/content-lake-app-deployment)** | Docker Compose stack that wires everything together (this repo) |
| [alfresco-content-lake-ui](https://github.com/AlfrescoLabs/alfresco-content-lake-ui) | ACA/ADW extension: semantic search + RAG chat sidebar |
| [content-lake-app-ui](https://github.com/AlfrescoLabs/content-lake-app-ui) | Standalone demo UI (Alfresco + Nuxeo dual auth) |
| [nuxeo-deployment](https://github.com/aborroy/nuxeo-deployment) | Local Nuxeo + PostgreSQL stack (required for Nuxeo profiles) |

## Quick start

```bash
git clone https://github.com/AlfrescoLabs/content-lake-app-deployment.git
cd content-lake-app-deployment
./setup.sh          # checks prerequisites, pulls AI models, prompts for credentials, starts the stack
```

The setup script handles everything for a first run. For manual control see [First Run](#first-run) below.

## Profiles

The stack supports four source profiles. Start with `alfresco` if you only have Alfresco:

```bash
make up-alfresco       # Alfresco + HXPR + RAG + ACA UI  (~14 services)
make up-nuxeo          # Nuxeo + HXPR + RAG  (~9 services, 2 from ../nuxeo-deployment)
make up-full           # Alfresco + Nuxeo + HXPR + RAG  (~18 services)
make up-demo           # full + standalone demo UI at /  (~19 services)
```

A mounted directory is one of those plugins since `content-lake-app#148`, in place of the retired
`filesystem` profile. Build `plugins/filesystem-connector` into [`connectors/`](connectors/), mount the
content at `CONNECTOR_HOST_PATH` (default `./filesystem-data`), and set `CONNECTOR_SOURCE_TYPE=filesystem`.
The `FILESYSTEM_*` setting names are unchanged, so an existing configuration carries over; the sync API is
guarded by `CONNECTOR_SYNC_USERNAME` and `CONNECTOR_SYNC_PASSWORD` rather than the retired
`FILESYSTEM_SYNC_*` pair, because a filesystem has no user directory to authenticate callers against and
neither has a default.

The `plugin-batch-ingester` is an opt-in service in its own `connector` profile, and it is the one that
ingests through a connector plugin. A jar in [`connectors/`](connectors/) is discovered by every ingester,
but the Alfresco and Nuxeo ingesters each drive a client they were compiled against, so for them a mounted
connector is only listed. This service takes its client, scope rules and optionally
its extractor from the jar, which means a new source needs no Maven module, no Dockerfile edit and no
change to `compose.content-lake.yaml`:

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  docker compose --profile alfresco --profile connector up -d --build plugin-batch-ingester

curl -u admin:admin http://localhost:9096/api/connectors
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured
```

Its source is that jar, so with `connectors/` empty it fails to start rather than idling. Set
`CONNECTOR_SOURCE_TYPE` when several jars are mounted, and `CONNECTOR_ROOTS` when the connector does not
name its own root container. Its sync API is guarded by one configured account, from
`CONNECTOR_SYNC_USERNAME` and `CONNECTOR_SYNC_PASSWORD`, with no defaults.
[`connectors/README.md`](connectors/README.md) has the rest, including how a connector's own settings are
passed in.

`sharepoint-mock` is a second opt-in profile, layered on top of `connector`. It runs `mock-graph` on
:8099, a stand-in for Microsoft Graph serving the SharePoint connector's own test fixtures, so that
connector can be run and demonstrated with no Microsoft 365 tenant. Test tooling rather than a product
service, and it is absent from all four base profiles, which `make verify-profiles` asserts.

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_DRIVE_IDS='b!mock-drive-id' \
SHAREPOINT_CLIENT_ID=mock SHAREPOINT_AUTH_MODE=static-token SHAREPOINT_ACCESS_TOKEN=mock-token \
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0 SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0 \
  docker compose --profile alfresco --profile connector --profile sharepoint-mock up -d
```

What it cannot stand in for is Entra ID: msal4j refuses an authority that is not `https`, so a mock run
uses `static-token` and proves nothing about app-only token acquisition. It also cannot say whether a real
tenant honours the `Prefer` headers, which is what `SHAREPOINT_PERMISSIONS_MODE=hierarchical` depends on.
Both are covered by the connector's own unit tests against the real library, not here.

For any profile that includes Nuxeo (`nuxeo`, `full`, `demo`), clone `nuxeo-deployment` as a sibling and start it first:

```bash
git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment
(cd ../nuxeo-deployment && docker compose up -d)
make up-full
```

No other sibling checkout is required -- all Java services build directly from GitHub via Docker BuildKit.

Important: profiles `nuxeo`, `full`, and `demo` do not start the Nuxeo server itself. The proxy
forwards `/nuxeo/*` to `http://host.docker.internal:8081`, so if `../nuxeo-deployment` is not
running you will get `502 Bad Gateway` on `http://localhost/nuxeo/`.

## Compose Layout

The stack is split across five files. `compose.yaml` is the only entrypoint -- it declares shared
infrastructure (network, named volumes, build secrets) and pulls in the rest via `include:`.

| File | Contents |
|---|---|
| [`compose.yaml`](compose.yaml) | Shared network, volumes, secrets + `include:` list |
| [`compose.alfresco.yaml`](compose.alfresco.yaml) | Alfresco: postgres, activemq, alfresco, transform-core-aio, batch-indexer\*, control-center\* |
| [`compose.hxpr.yaml`](compose.hxpr.yaml) | HXPR platform: hxpr-app, mongodb, opensearch, opensearch-dashboards (`debug` profile) |
| [`compose.content-lake.yaml`](compose.content-lake.yaml) | Content Lake services: batch-ingester, live-ingester, rag-service, nuxeo-batch-ingester, nuxeo-live-ingester, plugin-batch-ingester, mock-graph |
| [`compose.ui.yaml`](compose.ui.yaml) | UI and proxy: content-app, content-lake-app-ui (demo only), proxy |
| [`compose.observability.yaml`](compose.observability.yaml) | Trace backend for the RAG spans: otel-lgtm (`observability` profile) |

Always run from the project root using `make` or `docker compose` -- the included files are not
designed to be run in isolation.

## Connector Plugins

Every ingester mounts [`connectors/`](connectors/) read-only at `/opt/content-lake/connectors` and scans it
at startup, so a source connector can be shipped as a jar instead of as a module of `content-lake-app`.
That removes the whole ceremony an in-tree source needs: a Maven module, a line in an intermediate POM,
and a COPY line in the service build, which breaks a service's build when forgotten.

```bash
cp my-cmis-connector-1.0.0.jar connectors/
docker compose --profile alfresco up -d --force-recreate batch-ingester
curl http://localhost:9090/api/connectors -u admin:admin   # what loaded, from which jar, what failed
```

The directory is empty by default and an empty directory changes nothing. Override the mount with
`CONNECTOR_PLUGIN_PATH`. A jar that cannot be read, or whose configuration does not satisfy the schema it
publishes, is reported by that endpoint and in the log. The five ingesters that never ingest from a jar
start anyway (`CONNECTOR_VALIDATION` defaults to `warn` for them, since a connector they were not going to
use should not stop their own ingestion); `plugin-batch-ingester` defaults to `fail`, because for it that
jar is the only source. `CONNECTOR_VALIDATION_INGESTERS=fail` makes the other five strict as well.

`plugin-batch-ingester` also mounts one writable directory, published as `CONNECTOR_STATE_DIRECTORY`
(`/var/lib/content-lake/connector`), for state a connector cannot recompute such as a change cursor or a
delta token. It is a named volume, so `make clean` wipes it and `make down` does not, and a connector
should treat a missing cursor as normal. Nothing reads the variable by itself: a connector declares its
own setting and the operator points it at that path. See
[`connectors/README.md`](connectors/README.md).

Note that the connector's own settings still have to reach the service. A plugin declares the property
names it needs and reads them from the ingester's environment, so they are passed like any other setting.

Three connectors ship with the project, and `plugin-batch-ingester` already declares the settings of all
three, so each needs only its jar and its values:

| Connector | Source | Notes |
|---|---|---|
| `plugins/cmis-connector` | any CMIS 1.1 repository | `CMIS_*` settings |
| `plugins/sharepoint-connector` | SharePoint Online through Microsoft Graph | `SHAREPOINT_*` settings. Runs against the mock Graph service in the `sharepoint-mock` profile with no Microsoft 365 account at all |
| `plugins/filesystem-connector` | a mounted directory | `FILESYSTEM_*` settings, in place of the retired `filesystem` profile |

`../content-lake-app/plugins/examples/sample-directory-connector` is a hundred-line worked example to read
before writing one, and is not a source anyone should deploy.

SharePoint has one setting worth deciding before a first crawl. `SHAREPOINT_PERMISSIONS_MODE` defaults to
`per-item`, measured at 5.60 Graph resource units per document, which bounds a crawl near 200,000 documents
a day; `hierarchical` measures 1.10 but needs the `Sites.FullControl.All` application permission, and
refuses to run rather than degrade without it. [`connectors/README.md`](connectors/README.md) has the
figures and where they come from.

## Documentation

| Doc | Contents |
|---|---|
| [docs/deployment-alfresco.md](docs/deployment-alfresco.md) | Full stack prerequisites, credentials, first run, Alfresco requirements, configuration reference |
| [docs/deployment-nuxeo.md](docs/deployment-nuxeo.md) | Nuxeo stack setup, REST API reference, scope/auth config, audit live sync |
| [docs/deployment-rag.md](docs/deployment-rag.md) | RAG service configuration, REST API, security, conversation memory, observability |
| [docs/extraction.md](docs/extraction.md) | Text extraction paths, markdown vs plaintext, the `transform-extras` profile |
| [docs/DEPLOY_EC2.md](docs/DEPLOY_EC2.md) | Step-by-step guide to running the full stack on AWS EC2 |

## Service Topology

```mermaid
flowchart LR
  Browser["Browser"]
  ModelRunner["Docker Model Runner"]

  subgraph ACL["content-lake-app"]
    Proxy["proxy"]
    ContentApp["content-app"]
    DemoUi["content-lake-app-ui"]
    Batch["alfresco-batch-ingester"]
    Live["alfresco-live-ingester"]
    NuxeoBatch["nuxeo-batch-ingester"]
    NuxeoLive["nuxeo-live-ingester"]
    Rag["rag-service"]
  end

  subgraph ACS["Alfresco"]
    Alfresco["alfresco"]
    ControlCenter["control-center"]
    BatchIndexer["batch-indexer"]
    Postgres["postgres"]
    ActiveMQ["activemq"]
    Transform["transform-core-aio"]
  end

  subgraph NUXEO["Nuxeo (sibling stack)"]
    Nuxeo["nuxeo"]
    NuxeoDb["nuxeo-db"]
  end

  subgraph HXPR["hxpr"]
    HxprApp["hxpr-app"]
    Mongo["mongodb"]
    OpenSearch["opensearch"]
    OSD["opensearch-dashboards (debug)"]
  end

  Browser --> Proxy

  Proxy --> ContentApp
  Proxy --> DemoUi
  Proxy --> Alfresco
  Proxy --> ControlCenter
  Proxy --> Batch
  Proxy --> NuxeoBatch
  Proxy --> Nuxeo
  Proxy --> Rag

  ControlCenter --> Alfresco
  Alfresco --> Postgres
  Alfresco --> OpenSearch
  Alfresco --> ActiveMQ
  Alfresco --> Transform
  BatchIndexer --> Alfresco
  BatchIndexer --> Postgres
  BatchIndexer --> Transform
  BatchIndexer --> OpenSearch

  OSD --> OpenSearch

  Nuxeo --> NuxeoDb

  Batch --> ActiveMQ
  Batch --> Alfresco
  Batch --> Transform
  Batch --> HxprApp
  Batch -.-> ModelRunner

  Live --> ActiveMQ
  Live --> Alfresco
  Live --> Transform
  Live --> HxprApp
  Live -.-> ModelRunner

  NuxeoBatch --> Nuxeo
  NuxeoBatch --> HxprApp
  NuxeoBatch -.-> ModelRunner

  NuxeoLive --> Nuxeo
  NuxeoLive --> HxprApp
  NuxeoLive -.-> ModelRunner

  Rag --> Alfresco
  Rag --> Nuxeo
  Rag --> HxprApp
  Rag -.-> ModelRunner

  HxprApp --> Mongo
  HxprApp --> OpenSearch

```

Notes:

- `proxy` is the only public entrypoint for Alfresco, the UI, batch/sync APIs, and RAG APIs.
- `content-app` is exposed at `/aca/` in every profile where it is present (`alfresco`, `full`, `demo`).
- In `alfresco` and `full` profiles, `/` redirects to `/aca/`.
- In `demo` profile, `content-lake-app-ui` serves `/` and ACA remains at `/aca/`.
- In `nuxeo` profile, `/` redirects to `/nuxeo/`.
- The Nuxeo routes are active in `nuxeo`, `full`, and `demo` profiles, and require `../nuxeo-deployment` to be running.
- `opensearch-dashboards` is opt-in (`debug` profile) and published on port `5601`, not through
  `proxy`. It is unauthenticated, so keep it off unless you are debugging locally:
  `docker compose --profile demo --profile debug up -d opensearch-dashboards`.
- `otel-lgtm` is opt-in (`observability` profile) and published on port `3001`, not through `proxy`. It
  bundles an OTLP collector, Prometheus, Tempo and a Grafana with anonymous admin access, so it is for
  local development only. Point `MANAGEMENT_OTLP_TRACING_ENDPOINT` at it and set
  `RAG_OBSERVABILITY_PAYLOADS_ENABLED=true` to see what a RAG request retrieved and what it spent;
  `RAG_OBSERVABILITY_CAPTURE_CONTENT` additionally exports document content and is off by default.
  `make verify-profiles` asserts this and the other opt-in profiles never leak into a base profile.
- hxpr needs only `mongodb` and `opensearch`, matching the reference stack in
  `Hyland/ai-ready-index` (`server/hxpr-community-internal-app/docker-compose.yml`). The community
  app runs async tasks in memory and stores blobs locally, so there is no LocalStack (S3/SNS/SQS)
  or Nucleus mock in this stack.
- Alfresco and hxpr share the single `opensearch` cluster as two independent indices: `alfresco*`
  (repository search, fed by `batch-indexer`) and `nuxeo_embeddings*` (hxpr semantic search). There
  are no cross-index reads. On a clean deploy the batch indexer starts at "now" and indexes content
  created while it runs; the archive/trashcan search scope is not supported by the OpenSearch module.
- Docker Model Runner is an external dependency used by the Content Lake services, not a Compose service in this repository.

## What Had To Stay From The Alfresco Side

Before redesigning the deployment, the non-negotiable Alfresco-side requirements were:

- Alfresco Repository with the `content-lake-repo-model` module so `cl:indexed` and `cl:excludeFromLake` exist.
- ActiveMQ configured for Alfresco Event2 so `live-ingester` can consume `alfresco.repo.event2`.
- Alfresco Transform Core AIO for text extraction during ingestion.
- Alfresco repository search wired to OpenSearch (the `elasticsearch` index subsystem), fed by the
  `batch-indexer` service (Alfresco Search Community, ACS 26.2+), with `secureComms=secret`.
- A reverse proxy exposing `/`, `/alfresco/`, `/admin/`, `/api-explorer/`, and `/api/rag/`.

This repo vendors the required ACS module/config pieces locally and builds the rest of the stack around them.

## What This Repo Provides

- Local ACS repository image customization under `acs/alfresco`
- Vendored HXPR bootstrap assets under `hxpr/`
- Local HXPR Docker build that clones and compiles the requested HXPR branch
- Remote builds for `AlfrescoLabs/content-lake-app` and `AlfrescoLabs/alfresco-content-lake-ui`
- Remote build for `AlfrescoLabs/content-lake-app-ui` (demo profile) -- no local clone needed
- Docker Compose orchestration split across five focused `compose.*.yaml` files
- A single nginx config template replacing per-mode nginx files

## Source Contexts

By default, all Java services and UI images are built by pulling source from GitHub via Docker
BuildKit. No local checkouts are needed except `nuxeo-deployment` (sibling directory, see
Quick Start).

| Repo | Default source | Local override env var |
|---|---|---|
| `content-lake-app` | `github.com/AlfrescoLabs/content-lake-app#main` | `CONTENT_LAKE_GIT_CONTEXT=../content-lake-app` |
| `alfresco-content-lake-ui` | `github.com/AlfrescoLabs/alfresco-content-lake-ui#main` | `CONTENT_LAKE_UI_GIT_CONTEXT=../alfresco-content-lake-ui` |
| `content-lake-app-ui` | `github.com/AlfrescoLabs/content-lake-app-ui#main` | `CONTENT_LAKE_APP_UI_CONTEXT=../content-lake-app-ui` |
| `hxpr` | `github.com/Hyland/ai-ready-index` (branch from `HXPR_GIT_REF`) | `HXPR_LOCAL_IMAGE=<local-tag>` |
| `nuxeo-deployment` | sibling directory `../nuxeo-deployment` (required for Nuxeo profiles) | -- |

To build everything from local source (useful during active development):

```bash
make up-demo local
```

The `local` parameter sets all four `*_CONTEXT` overrides automatically and forces `--no-cache` so local source changes are always picked up.

## Prerequisites

- Docker Desktop with Docker Compose v2
- Docker Model Runner -- enable in Docker Desktop settings, or install `docker-model-plugin` on Linux
- Access to `ghcr.io` for Hyland images
- Outbound access to GitHub so BuildKit can fetch the remote source contexts
- `HXPR_GIT_AUTH_TOKEN` while `Hyland/ai-ready-index` is private (needed for the source clone)
- Optional `MAVEN_USERNAME`/`MAVEN_PASSWORD`/`NEXUS_USERNAME`/`NEXUS_PASSWORD` only if the engine
  build resolves a private artifact from the `hylandsoftware-releases` Nexus repo

## Getting Credentials

The engine is built from `Hyland/ai-ready-index`. That repository is currently private, so a source
clone needs a GitHub token; the Maven build otherwise resolves from public repositories.

**`HXPR_GIT_AUTH_TOKEN`** -- required while `https://github.com/Hyland/ai-ready-index.git` is private.
Use a GitHub classic token with `repo` scope, or a fine-grained token scoped to `Hyland/ai-ready-index`
with read access to repository contents.

**`MAVEN_USERNAME` / `MAVEN_PASSWORD` / `NEXUS_USERNAME` / `NEXUS_PASSWORD`** -- optional. Only set
them if the build fails resolving a private artifact from the `hylandsoftware-releases` Nexus repo
(`https://artifacts.alfresco.com/nexus/content/repositories/hylandsoftware-releases`). When unset,
the build proceeds anonymously.

### Credentials committed to this repository

Every credential in the tracked `.env` is a local development default and is world-readable, so this
stack is safe to run on a laptop and not safe to expose. Before putting it on any host reachable by
someone else, change at least these:

| Key | Committed default | Why it matters |
|---|---|---|
| `ALFRESCO_ADMIN_PASSWORD`, `HXPR_PASSWORD`, `NUXEO_PASSWORD` | vendor defaults (`admin`, `password`, `Administrator`) | administrator on the repository and on the engine |
| `OPENSEARCH_ADMIN_PASSWORD` | a fixed value that satisfies the OpenSearch password policy | looks like a real password but is published here |
| `SHARED_SECRET` | a fixed string | the Alfresco to Solr shared secret; anyone holding it can talk to Solr as the repository |
| `POSTGRES_PASSWORD`, `ACTIVEMQ_PASSWORD` | vendor defaults | direct database and broker access |

`CONNECTOR_SYNC_USERNAME` and `CONNECTOR_SYNC_PASSWORD` are deliberately the exception: they ship
empty and the service refuses to start until you supply them, because the endpoint they guard
triggers a full re-ingest. Put overrides for any of the above in `.env.local`, which is not tracked.

## First Run

1. Authenticate to GitHub Container Registry:

   ```bash
   docker login ghcr.io
   ```

2. Enable Docker Model Runner in Docker Desktop.

3. Prepare the AI models once:

   ```bash
   docker model pull ai/mxbai-embed-large
   make olmo3-local
   ```

   The default chat model is Olmo 3 7B Instruct (`local/olmo3-7b-instruct:Q4_K_M`).
   `make olmo3-local` creates it. You can skip that step: every `make up-*` target
   runs `make ensure-llm` first, which creates the model when it is missing. Do not point `LLM_MODEL` at an Olmo 3 GGUF from
   Hugging Face directly: its chat template makes llama.cpp abort at load, and
   every chat request returns 500. The make target packages the same weights with
   a corrected template. See [Why Olmo 3](#why-olmo-3).

   To use Qwen 2.5 instead, run `docker model pull ai/qwen2.5` and set
   `LLM_MODEL=ai/qwen2.5` in `.env.local`.

4. Put your credentials in `.env.local` (never committed):

   ```bash
   cat >> .env.local <<'EOF'
   MAVEN_USERNAME=...
   MAVEN_PASSWORD=...
   NEXUS_USERNAME=...
   NEXUS_PASSWORD=...
   EOF
   ```

5. Start the stack:

   ```bash
   make up-alfresco      # Alfresco only (most common)
   make up-full          # Alfresco + Nuxeo (requires ../nuxeo-deployment)
   make up-nuxeo         # Nuxeo only
   make up-demo          # demo UI at /
   ```

   Or use the guided script: `./setup.sh [alfresco|nuxeo|full|demo]`

For any profile that includes Nuxeo:

```bash
git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment
(cd ../nuxeo-deployment && docker compose up -d)
make up-full
```

If `http://localhost/nuxeo/ui` returns `502 Bad Gateway`, check that `../nuxeo-deployment` is running and reachable on port 8081.

## Why Olmo 3

[Olmo 3](https://huggingface.co/collections/allenai/olmo-3) from Ai2 (Allen Institute
for AI) is one of the few LLMs that is open source in full, not only "open weights".
Most models that you can download publish the final weights and nothing else. Ai2
also publishes the parts that you need to study, rebuild or audit the model:

| Part | Where |
| --- | --- |
| Weights, Apache 2.0 | [allenai/Olmo-3-7B-Instruct](https://huggingface.co/allenai/Olmo-3-7B-Instruct), and a 32B version, [allenai/Olmo-3.1-32B-Instruct](https://huggingface.co/allenai/Olmo-3.1-32B-Instruct) |
| Pre-training data | Dolma 3 |
| Post-training data | Dolci (for example [allenai/Dolci-Instruct-RL](https://huggingface.co/datasets/allenai/Dolci-Instruct-RL)) |
| Training code | [allenai/OLMo-core](https://github.com/allenai/OLMo-core) |
| Checkpoints of every stage | base, SFT, DPO and final models, all on Hugging Face |
| Technical report | [arXiv 2512.13961](https://arxiv.org/abs/2512.13961) |

This matters for Content Lake. The project keeps the documents, the index and the
inference on infrastructure that you run. With Olmo 3 the model follows the same
rule: you can see what data it was trained on and how, and nothing depends on a
licence that a vendor can change.

| Deployment | Model | Why |
| --- | --- | --- |
| Local (Docker Model Runner) | Olmo 3 7B Instruct, Q4_K_M GGUF, about 4.2 GB | Runs on a laptop. This is the recommended model |
| EC2 (vLLM on the A10G) | Qwen 2.5 14B Instruct, 4-bit AWQ | Olmo 3 needs more GPU memory than this host has, see below |

Olmo 3 is the default for local deployment. Qwen 2.5 (`ai/qwen2.5`) is still supported; it publishes weights only, under Apache 2.0.

Running Olmo 3 with vLLM needs more resources than the `g5.2xlarge` in
[DEPLOY_EC2.md](docs/DEPLOY_EC2.md). Its A10G has 22.5 GB usable, shared by vLLM and
the two TEI services (embeddings and reranker):

- Olmo 3 7B in bf16 takes about 19.8 GB in vLLM (13.6 GB weights, 4.3 GB cache for a
  16k-token context). It starts and answers well, but under ingestion load both TEI
  services run out of GPU memory and return errors, while their health checks stay green.
- Olmo 3.1 32B does not fit at all: even in 4-bit it leaves room for about 11k tokens
  of context, and rag-service needs 16k.

To run Olmo 3 on a GPU host, use a card with 48 GB, for example a `g6e.xlarge` (NVIDIA
L40S), or run TEI on a second GPU.

## Public Endpoints

Only the proxy is published on the host on port `80`.

| URL | Available in profiles |
|---|---|
| `http://localhost/` | Redirects to `/aca/` (alfresco/full), `/nuxeo/` (nuxeo), or demo UI (demo) |
| `http://localhost/aca/` | alfresco, full, demo |
| `http://localhost/alfresco/` | alfresco, full, demo |
| `http://localhost/admin/` | alfresco, full, demo |
| `http://localhost/api-explorer/` | alfresco, full, demo |
| `http://localhost/nuxeo/` | nuxeo, full, demo |
| `http://localhost/api/rag/` | all profiles |
| `http://localhost/api/content-lake/` | alfresco, full, demo |
| `http://localhost/api/sync/` | all profiles (routes to the alfresco or nuxeo ingester via `?sourceType=`) |
| `http://localhost:5601/` | OpenSearch Dashboards, `debug` profile only (opt-in, unauthenticated) |

## Nuxeo Demo Content

To seed a sample file in the local Nuxeo stack without using the Web UI,
start `../nuxeo-deployment` and run a Nuxeo-enabled profile, then use
[scripts/create-nuxeo-demo-file.sh](scripts/create-nuxeo-demo-file.sh):

```bash
./scripts/create-nuxeo-demo-file.sh
./scripts/create-nuxeo-demo-file.sh --title "Quarterly Notes" --text $'Line 1\nLine 2'
./scripts/create-nuxeo-demo-file.sh --input-file README.md --mime-type text/markdown
```

To verify indexing afterwards:

```bash
curl -u Administrator:Administrator -X POST 'http://localhost/api/sync/configured?sourceType=nuxeo'
```

## Configuration

Defaults live in `.env`. To override locally, create `.env.local` with only the variables you want to change:

```bash
# Example .env.local
HXPR_GIT_REF=main
PUBLIC_PORT=9090
```

`.env.local` is listed in `.gitignore` and is never committed.

> **Note:** Docker Compose only auto-loads `.env`. The Makefile passes `--env-file .env.local`
> automatically when the file exists. If you run `docker compose` directly, add the flag yourself.

Key overrides:

| Variable | Default | Description |
|---|---|---|
| `HXPR_GIT_URL` | `https://github.com/Hyland/ai-ready-index.git` | Engine source repo |
| `HXPR_GIT_REF` | `main` | Branch or tag to build |
| `HXPR_GIT_SHA` | *(empty)* | Pin to a specific commit SHA for reproducible builds |
| `HXPR_LOCAL_IMAGE` | `content-lake-app/hxpr-app:local` | Local image tag for the built HXPR app |
| `CONTENT_LAKE_GIT_CONTEXT` | `https://github.com/AlfrescoLabs/content-lake-app.git#main` | Java source context |
| `CONTENT_LAKE_UI_GIT_CONTEXT` | `https://github.com/AlfrescoLabs/alfresco-content-lake-ui.git#main` | ACA extension context |
| `CONTENT_LAKE_APP_UI_CONTEXT` | `https://github.com/AlfrescoLabs/content-lake-app-ui.git#main` | Demo UI context (override to `../content-lake-app-ui` for local dev) |
| `ACA_TAG` | `7.4.1` | Alfresco Content App version |
| `PUBLIC_PORT` | `80` | Host port for the proxy |
| `DEMO_UI_PORT` | `4200` | Direct host port for the demo UI container |
| `MODEL_RUNNER_URL` | `http://model-runner.docker.internal` | LLM/embedding inference backend |
| `EMBEDDING_MODEL` | `ai/mxbai-embed-large` | Embedding model |
| `LLM_MODEL` | `local/olmo3-7b-instruct:Q4_K_M` | Chat/RAG model. Run `make olmo3-local` once to create it |
| `EXTRACTION_FORMAT` | `plaintext` | `plaintext`, `auto` or `markdown`. Whether extraction asks a transform engine for markdown, so headings and tables survive chunking. See [docs/extraction.md](docs/extraction.md) |
| `TRANSFORM_URL` | `http://transform-core-aio:8090` | Transform engine for the Alfresco ingesters. Point at `http://transform-liteparse:8090` or `http://transform-convert2md:8090` with the `transform-extras` profile |
| `EXTRACTION_ENGINE_URL` | *(empty)* | Transform engine for the Nuxeo ingesters and any plugin connector, which have none by default. Empty leaves them on in-process Tika |
| `EXTRACTION_ENGINE_TIMEOUT_MS` | `300000` | Read timeout for the above. Do not lower it: `convert2md` needs tens of seconds per PDF |
| `TRANSFORM_EXTRAS_TAG` | `1.1.0` | `transform-liteparse` image tag. 1.1.0 or newer is required for spreadsheet tables |
| `TRANSFORM_CONVERT2MD_TAG` | `1.1.0` | `transform-convert2md` image tag |

On Linux, override `MODEL_RUNNER_URL=http://host.docker.internal:12434` in `.env.local`.

## Day-to-day commands

```bash
make up-alfresco      # build and start Alfresco profile
make up-nuxeo         # build and start Nuxeo profile
make up-full          # build and start full profile
make up-demo          # build and start demo profile
make down             # stop and remove containers (volumes preserved)
make logs             # follow logs for all services
make ps               # show running services and health
make config           # render the resolved compose configuration
make clean            # stop + remove all volumes [DESTRUCTIVE]
```

You can also call `docker compose` directly; remember to add `--env-file .env.local` and `--profile <name>` explicitly.

## Smoke Test

`test/smoke-test.sh` is a self-contained end-to-end smoke test that runs against any live
deployment -- local or EC2 -- without stopping services or touching existing data. The
environment is left identical to its state before the test: every document, user, workspace,
and log file created during the run is deleted before the script exits.

### When to run it

- **After deploying a new build** -- confirms the full ingest-to-search pipeline is intact.
- **After any configuration change** -- credentials, compose overrides, nginx rules, etc.
- **After an EC2 restart** -- verifies all services came back up healthy.
- **Before a demo** -- quick sanity check that the stack is working end to end.

### What it covers

| Section | What is verified |
|---|---|
| A -- Service health | RAG service UP (embedding, hxpr, LLM sub-components), Alfresco responds, Nuxeo responds, unauthenticated request returns 401, sync API reachable |
| B -- Alfresco batch ingest | Creates a folder + document, triggers `/api/sync/batch`, waits for sync completion and embedding, verifies the document appears in hybrid search |
| C -- Nuxeo live ingest | Creates a Nuxeo document, waits for the audit-poll cycle, verifies it appears in hybrid search |
| D -- Cross-source search | A single query returns results from both Alfresco and Nuxeo in one response |
| E -- Apostrophe regression | Query containing `'` (e.g. "king arthur's legend") completes without a NXQL parse error |
| F -- RAG prompt | `/api/rag/prompt` returns a non-empty LLM answer with source citations |
| F2 -- Semantic search | `/api/rag/search/semantic` (vector-only path used by the demo app search panel) returns the Alfresco fixture |
| F3 -- Source-type filter | `sourceType=alfresco` on hybrid search returns the Alfresco doc and excludes the Nuxeo doc |
| F4 -- Streaming chat | `/api/rag/chat/stream` (SSE endpoint used by the demo chat UI) opens and emits data lines |
| F5 -- Node status | `/api/content-lake/nodes/{id}/status` returns a `status` field (used by the ACA extension) |
| G -- Cleanup + delete propagation | All created documents, users, and workspaces are deleted; Alfresco and Nuxeo docs disappear from search after deletion; log file is removed |

### How to run

All credentials must be supplied as environment variables -- no defaults are hardcoded.

**Local stack:**

```bash
HOST=localhost \
  ALF_AUTH=admin:admin \
  NUXEO_AUTH=Administrator:Administrator \
  NUXEO_PORT=8081 \
  NUXEO_WORKSPACE=content-lake-smoke \
  ./test/smoke-test.sh
```

**EC2 (or any remote host):**

```bash
HOST=demo.example.com \
  ALF_AUTH=admin:<alfresco-password> \
  NUXEO_AUTH=Administrator:<nuxeo-password> \
  ./test/smoke-test.sh
```

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ALF_AUTH` | yes | -- | Alfresco admin credentials (`user:password`) |
| `NUXEO_AUTH` | yes | -- | Nuxeo admin credentials (`user:password`) |
| `HOST` | no | `localhost` | Target hostname or IP |
| `NUXEO_PORT` | no | `80` | Nuxeo port (80 = through nginx proxy; 8081 = direct, local only) |
| `NUXEO_WORKSPACE` | no | `content-lake-smoke` | Nuxeo workspace used for test documents -- created automatically if absent. `content-lake-smoke` is treated as a disposable smoke workspace and deleted during cleanup even if it existed before the run. |
| `WAIT_LIVE_S` | no | `60` | Seconds to wait for the Nuxeo live-ingester audit poll |
| `WAIT_EMBED_S` | no | `30` | Seconds to wait for the embedding pipeline after Alfresco sync |
| `TOPK` | no | `30` | `topK` used for presence checks in search results |

### Expected output

```
  Passed : 28
  Failed : 0
```

A non-zero `Failed` count means at least one pipeline stage is broken. The script writes a
`smoke-test-<timestamp>.log` file during the run containing the full output including top-3
search results for every failed assertion; this file is deleted at the end of a successful
run. If the script is interrupted or exits with failures, the log file is kept for inspection.

## Connector Suite

`test/test-connector.sh` proves the plugin path end to end: it builds the sample connector from
`../content-lake-app/plugins/examples/sample-directory-connector` inside a Maven container,
drops the jar into `connectors/`, starts `plugin-batch-ingester` on top of a base stack that is already
running, triggers a sync and asserts the fixture documents come back out of semantic search.

Opt-in, like the profile it exercises, so it is not a phase of `test/run-tests.sh`. It needs a base stack
up, the AI backend on :12434, and Docker.

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  RAG_AUTH=admin:admin ./test/test-connector.sh
```

It removes the service and the jar on exit; pass `KEEP_RUNNING=true` to keep both for poking at.

## CMIS Suite

`test/test-cmis.sh` is the same shape for the shipped CMIS connector
(`../content-lake-app/plugins/cmis-connector`), and it checks the one thing a generic adapter has to be
held to: that it ingests what the purpose-built adapter ingests. It creates a folder of fixtures in the
running Alfresco, syncs it with the native adapter, then syncs the same folder over Alfresco's own CMIS
endpoint and compares the two document sets. It also restricts one fixture to `admin` with inheritance off
and asserts that a second user cannot retrieve it while the folder's public fixture stays readable, which is
the ACL mapping working rather than being skipped.

Unlike `test-connector.sh` it pins no `RAG_PERMISSION_SOURCE_IDS`: since #133 the permission filter
discovers every source in the index, so a pin would mask exactly what needs proving.

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  RAG_AUTH=admin:admin ./test/test-cmis.sh
```

One case it deliberately does not cover, and says so in its own output: a repository reporting
`capabilityACL=NONE`. Alfresco reports `manage`, so the fail-closed refusal and the `sync-account` and
`public` fallbacks are unit-tested in the connector instead.

## SharePoint Suite

`test/test-sharepoint.sh` is the same shape again for the shipped SharePoint connector
(`../content-lake-app/plugins/sharepoint-connector`), run against the `sharepoint-mock` profile rather than
a tenant. The mock is the target by necessity, not convenience: registering an application is disabled in
the tenant available here, and a SharePoint site a developer is only a member of returns a **truncated**
ACL, so it cannot validate permission mapping at all. Exactly two things differ from the cloud, the Graph
base URL and the token provider, and both are configuration.

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  RAG_AUTH=admin:admin ./test/test-sharepoint.sh
```

Three passes over the same fixture tree: a walk, an incremental pass through the change feed that applies a
tombstone, and a third in `hierarchical` permissions mode under a second source id. It also creates two
Alfresco callers and switches `rag-service`'s Entra group resolver on, restoring it afterwards, because the
assertions that matter are about whether an ACL is actionable rather than merely recorded:

- a document granted to one named user is not retrievable by another, in either permissions mode;
- a document granted only to an Entra group **is** retrievable by a member of that group and is not by
  anyone else;
- a `users`-scoped sharing link grants the named identities and nobody else;
- the cost per document is reported in both permissions modes and compared, rather than estimated;
- with the mock honouring no `Prefer` header, `hierarchical` mode refuses instead of silently paying the
  per-item price.

What no mock run can establish, and what still needs a tenant: real payload fidelity beyond the fixtures
(written from Microsoft's documented shapes, not recorded), app-only token acquisition, genuine throttling
behaviour, and whether SharePoint honours the `Prefer` headers at all. Do not read a green run as evidence
of any of those four.

## Deploying to AWS EC2

See [docs/DEPLOY_EC2.md](docs/DEPLOY_EC2.md) for a step-by-step guide to running the full stack on a `g5.2xlarge` (8 vCPU / 32 GB RAM / NVIDIA A10G GPU, 24 GB VRAM) Ubuntu instance, including vLLM, TEI, and nginx proxy installation for GPU-accelerated inference.

## Notes

- The engine is built from source (`Hyland/ai-ready-index`) during `docker compose up --build` using `HXPR_GIT_REF` (default: `main`).
- The source clone needs `HXPR_GIT_AUTH_TOKEN` while the repo is private; the Maven build otherwise resolves from public repositories (Nexus/GitHub-Packages credentials are optional build secrets, used only if a private artifact is required).
- content-lake-app authenticates to the engine with HTTP Basic (`HXPR_USERNAME` / `HXPR_PASSWORD`).
- All Content Lake Java services (`batch-ingester`, `live-ingester`, ingesters, `rag-service`) build from source fetched directly from GitHub -- no local Java checkout needed.
- The repository model is injected directly into the Alfresco image from this repo.
- The ACA UI is exposed at `/aca/` in every profile where it is enabled, so its context path stays stable across stacks.
- The demo UI (`content-lake-app-ui`) is served at `/` only in the `demo` profile.
- The demo UI is a demonstration, not a reference authentication implementation. It persists the
  Alfresco ticket (revocable) but holds the Nuxeo `base64(user:pass)` credential in memory only, so
  reloading the page keeps the Alfresco session and ends the Nuxeo one.

## Known Assumption

This repo builds the `main` branch of `Hyland/ai-ready-index`. While that repository is private the source clone needs `HXPR_GIT_AUTH_TOKEN`. To build a different branch or repo URL, override `HXPR_GIT_URL` and `HXPR_GIT_REF` in `.env.local`.
