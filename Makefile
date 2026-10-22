# =============================================================
# Content Lake — Deployment Makefile
# =============================================================
# Usage:
#   make up-alfresco        Alfresco + HXPR + RAG + ACA UI  (~14 services)
#   make up-nuxeo           Nuxeo + HXPR + RAG  (~9 services, 2 from ../nuxeo-deployment)
#   make up-full            Alfresco + Nuxeo + HXPR + RAG  (~18 services)
#   make up-demo            Full + standalone demo UI at /  (~19 services)
#   make up-alfresco-2      Alfresco + a second, independent Alfresco + HXPR + RAG  (~21 services).
#                           Loads compose.alfresco-2.yaml on top of compose.yaml with profiles alfresco and
#                           alfresco-2: postgres-2, activemq-2, alfresco-2, batch-indexer-2, batch-ingester-2,
#                           live-ingester-2 and content-app-2, served on :8082 (ALFRESCO_2_PUBLIC_PORT).
#                           The JVM services of both instances get a mem_limit, ~13.5g in total by default.
#                           rag-service lists both as rag.sources[]; set ALFRESCO_1_SOURCE_ID and
#                           ALFRESCO_2_SOURCE_ID to their repository ids once both have bootstrapped
#                           (README.md, "Second Alfresco instance").
#   make up-platform        Platform only: hxpr + RAG + demo UI, no Alfresco and no Nuxeo (~6 services).
#                           The base profile for running a connector jar as the single source: pair it with
#                           --profile connector. Nothing can authenticate a caller in this shape yet, so
#                           /api/rag answers 401 until content-lake-app#167 lands; ingestion and the
#                           operator endpoints work.
#   Plugin connector (opt-in): add the 'connector' profile to a base stack, e.g.
#     CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#       docker compose --profile alfresco --profile connector up -d --build plugin-batch-ingester
#     (ingests through a connector jar in ./connectors, on :9096. The jar is its only source, so the
#      service fails to start with that directory empty. Supply the connector's own settings as
#      environment variables using the names its schema declares -- hyphens become underscores, so
#      `sample-directory.root-path` is SAMPLE_DIRECTORY_ROOT_PATH -- then POST /api/sync/configured.
#      GET /api/connectors lists what loaded and anything that failed to)
#     Set CONNECTOR_SOURCE_TYPE even when the jar is the only one mounted: besides selecting the
#     connector, it is what routes /api/sync through the proxy. The proxy picks a backend from the
#     request's ?sourceType, and the entry for this host is rendered from that variable, because the
#     source type a mounted jar declares is not knowable when the nginx config is written. Without it
#     a sync request reaches the default backend, which is the Alfresco ingester.
#     The operator endpoints are proxied same-origin on the base stack's port, not only on :9096 --
#     /api/connectors, /api/browse, /api/selection, and /api/connector-status for the host's own
#     last-run summary (/api/status stays rag-service's). :9096 remains published, so diagnosing a jar
#     that did not load never depends on the proxy.
#     Which roots a pass walks is readable and writable at /api/selection without a restart, because
#     CONNECTOR_SELECTION_STORE defaults to hxpr here. The application's own default is `none`, which
#     answers 501 -- so an unconfigured deployment has the endpoint and no store behind it. A selection
#     lives in the index, so `make clean` wipes it; a restart does not.
#     To manage all of that from the demo UI's Sources screen, add CONNECTORS_URL=/api/connectors to the
#     'demo' profile's environment. It is empty by default, which hides the screen and its nav entry: the
#     connector profile is opt-in, so a demo stack without one has no host and a screen answering 502 is
#     worse than an absent screen. Same-origin through the proxy, so the browser sends this origin's
#     credential. The screen also needs CONNECTOR_SYNC_USERNAME/PASSWORD, which it prompts for.
#     The filesystem source runs this way since content-lake-app#148, in place of its own profile:
#       CONNECTOR_SOURCE_TYPE=filesystem FILESYSTEM_ROOT_PATH=/data/connector \
#       CONNECTOR_HOST_PATH=./filesystem-data CONNECTOR_SYNC_USERNAME=admin \
#       CONNECTOR_SYNC_PASSWORD=admin \
#         docker compose --profile alfresco --profile connector up -d
#     (build the jar with `mvn -f plugins/filesystem-connector/pom.xml package` and copy it into
#      ./connectors/ first; the setting names are the ones the old profile used)
#   Mock Microsoft Graph (opt-in): add the 'sharepoint-mock' profile alongside 'connector', e.g.
#     CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#     CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_AUTH_MODE=static-token \
#     SHAREPOINT_ACCESS_TOKEN=mock-token SHAREPOINT_CLIENT_ID=mock \
#     SHAREPOINT_DRIVE_IDS='b!mock-drive-id' \
#     SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0 \
#     SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0 \
#       docker compose --profile alfresco --profile connector --profile sharepoint-mock up -d
#     (a stand-in for Microsoft Graph on :8099, so the SharePoint connector can be run without a
#      Microsoft 365 tenant. Test tooling, not a product service. Needs the sharepoint-connector jar in
#      ./connectors, and static-token auth because msal4j refuses any authority that is not https.
#      MOCK_GRAPH_HONOURED_PREFERENCES='' simulates a tenant without Sites.FullControl.All, which
#      SHAREPOINT_PERMISSIONS_MODE=hierarchical then refuses to run against; ./test/test-sharepoint.sh
#      drives both. MOCK_GRAPH_THROTTLE_EVERY=3 makes it answer 429 with a Retry-After, which the suite
#      does not exercise: the connector's own GraphHttpClientTest covers the pause-and-resume.
#      It also reports on itself, which is the quickest way to see what a connector actually asked for:
#        curl -s localhost:8099/mock-diagnostics/requests | jq .
#        curl -s 'localhost:8099/mock-diagnostics/requests?contains=f-public/children' | jq .count
#        curl -sX DELETE localhost:8099/mock-diagnostics/requests      # reset, to measure one pass alone
#      Outside /v1.0 and needing no bearer token, because it is not part of the surface being mocked, and
#      asking is not itself recorded)
#   SharePoint as a named user (no app registration with application permissions needed): sign in once on
#   this host, then run the connector against the real tenant unattended.
#     export SHAREPOINT_CLIENT_ID=<application (client) id of the public-client registration>
#     export SHAREPOINT_TENANT_ID=<directory (tenant) id>
#     ./scripts/sharepoint-device-login.sh
#     CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_AUTH_MODE=device-code \
#     SHAREPOINT_CLIENT_ID=$$SHAREPOINT_CLIENT_ID SHAREPOINT_TENANT_ID=$$SHAREPOINT_TENANT_ID \
#     SHAREPOINT_DRIVE_IDS='<drive id>' \
#     CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
#       docker compose --profile alfresco --profile connector up -d
#     (the sign-in prints a code and a URL, waits for a browser, and writes ./sharepoint-auth/msal-cache.json,
#      which is bind-mounted read-only into the ingester. That file holds a refresh token: it is gitignored,
#      chmod 600, and is a credential. The script exists because slf4j-api is `provided` for the plugin, so
#      the jar cannot be run with `java -jar`.
#      Two things to know before choosing this mode over client-credentials. It indexes one identity's view,
#      so anything the signed-in user cannot read is absent from the index rather than present and
#      unretrievable. And the mount is read-only, so refreshed tokens are held in memory and the sign-in has
#      to be repeated when the stored refresh token finally expires, or after a password reset or a
#      Conditional Access change. The connector reports the mode as unsupported for production at startup
#      for that reason)
#   OpenSearch Dashboards (opt-in): add the 'debug' profile to a base stack, e.g.
#     docker compose --profile demo --profile debug up -d opensearch-dashboards
#     (unauthenticated UI on :5601 over the cluster holding alfresco* and nuxeo_embeddings*)
#   Markdown extraction (opt-in): add the 'transform-extras' profile to a base stack, e.g.
#     EXTRACTION_FORMAT=auto TRANSFORM_URL=http://transform-liteparse:8090 \
#       docker compose --profile alfresco --profile transform-extras up -d
#     (adds the liteparse T-Engine, which converts PDF/DOCX/XLSX/PPTX/DOC to Markdown so tables
#      survive chunking as ChunkType.TABLE instead of being flattened into prose. EXTRACTION_FORMAT
#      defaults to 'plaintext', so the profile on its own changes nothing -- set auto or markdown.
#      For Nuxeo and for a plugin connector use EXTRACTION_ENGINE_URL instead of TRANSFORM_URL.
#      liteparse recovers headings but NOT tables (~0.3s/PDF); transform-convert2md recovers real
#      markdown tables but costs ~20s/PDF and is PDF-only. Point the URL at whichever fits the corpus.
#      Extraction always degrades to Tika, so a missing or slow engine never fails an ingest)
#   Trace backend (opt-in): add the 'observability' profile to a base stack, e.g.
#     MANAGEMENT_OTLP_TRACING_ENDPOINT=http://otel-lgtm:4318/v1/traces \
#     RAG_OBSERVABILITY_PAYLOADS_ENABLED=true \
#       docker compose --profile demo --profile observability up -d
#     (Grafana on :3001 with anonymous admin; development only. Read docs/deployment-rag.md before
#      enabling RAG_OBSERVABILITY_CAPTURE_CONTENT: it exports ACL-protected document content)
#   make down               Stop all services
#   make logs               Follow logs
#   make ps                 Show service status
#   make verify-profiles    Assert every opt-in profile stays opt-in
#   make config             Dry-run: render resolved compose configuration
#   make clean              Stop + remove all volumes  [DESTRUCTIVE]
#
# Local development mode:
#   Add 'local' as a parameter to use local sibling directories instead of git branches:
#   make up-demo local      Uses ../content-lake-app, ../content-lake-app-ui, etc.
#   make up-alfresco local  Build from local checkouts
#
# AI inference backend (both serve on host port 12434 — run only one at a time):
#   Dev  — enable Docker Model Runner in Docker Desktop. Every up-* target runs ensure-llm first,
#          which packages the default Olmo 3 model (or pulls an ai/* LLM_MODEL) when it is missing
#   Prod — make start-ai   Start TEI + vLLM stack (requires NVIDIA GPU / compose.ai.yaml)
#          make stop-ai    Stop the TEI + vLLM stack
# =============================================================

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# Check if 'local' is passed as an argument
ifneq (,$(filter local,$(MAKECMDGOALS)))
  USE_LOCAL := 1
  LOCAL_ENV_OVERRIDES := \
    CONTENT_LAKE_GIT_CONTEXT=../content-lake-app \
    CONTENT_LAKE_ACS_GIT_CONTEXT=../content-lake-app \
    CONTENT_LAKE_UI_GIT_CONTEXT=../alfresco-content-lake-ui \
    CONTENT_LAKE_APP_UI_CONTEXT=../content-lake-app-ui
else
  LOCAL_ENV_OVERRIDES :=
endif

LOAD_ENV := set -a && . ./.env && if [ -f ./.env.local ]; then . ./.env.local; fi && set +a &&

ifneq (,$(wildcard .env.local))
  ENV_ARGS := --env-file .env.local
else
  ENV_ARGS :=
endif

DC := $(LOAD_ENV) docker compose $(ENV_ARGS)

# The second Alfresco instance is an override file, not an include, so it is appended to COMPOSE_FILE
# rather than passed with -f: -f would drop a COMPOSE_FILE set in .env.local (compose.hxpr-build.yaml).
ALFRESCO_2_COMPOSE_FILE := COMPOSE_FILE="$${COMPOSE_FILE:-compose.yaml}:compose.alfresco-2.yaml"
ALFRESCO_2_SERVICES := postgres-2 activemq-2 alfresco-2 batch-indexer-2 batch-ingester-2 live-ingester-2 content-app-2

# Commands that act on whatever is running (down, clean, logs, ps) load the override too, so the second
# instance's containers and volumes are not left behind. Loading it adds nothing to a base profile.
DC_ALL := $(LOAD_ENV) $(ALFRESCO_2_COMPOSE_FILE) docker compose $(ENV_ARGS)

.PHONY: help up-alfresco up-alfresco-2 up-nuxeo up-full up-demo up-platform down logs ps config clean start-ai stop-ai olmo3-local ensure-llm local verify-profiles

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' Makefile | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

local: ## Placeholder target for 'local' parameter — use: make up-demo local
	@:

up-alfresco: ensure-llm ## Alfresco source -- core services (~17)
ifdef USE_LOCAL
	@echo "→ Building from local sibling directories (../content-lake-app, ../alfresco-content-lake-ui)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile alfresco build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile alfresco up --build -d
	@$(call _urls,alfresco)

up-alfresco-2: ensure-llm ## Alfresco + a second, independent Alfresco on :8082 (opt-in alfresco-2 profile)
ifdef USE_LOCAL
	@echo "-> Building from local sibling directories (../content-lake-app, ../alfresco-content-lake-ui)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) $(ALFRESCO_2_COMPOSE_FILE) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile alfresco --profile alfresco-2 build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) $(ALFRESCO_2_COMPOSE_FILE) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile alfresco --profile alfresco-2 up --build -d
	@$(call _urls,alfresco-2)

up-nuxeo: ensure-llm ## Nuxeo source — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
ifdef USE_LOCAL
	@echo "→ Building from local sibling directories (../content-lake-app)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=nuxeo-batch-ingester:9093 \
	  NGINX_ROOT_DIRECTIVE="return 302 /nuxeo/;" \
	  docker compose $(ENV_ARGS) --profile nuxeo build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=nuxeo-batch-ingester:9093 \
	  NGINX_ROOT_DIRECTIVE="return 302 /nuxeo/;" \
	  docker compose $(ENV_ARGS) --profile nuxeo up --build -d
	@$(call _urls,nuxeo)

up-full: ensure-llm ## Alfresco + Nuxeo — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
ifdef USE_LOCAL
	@echo "→ Building from local sibling directories (../content-lake-app, ../alfresco-content-lake-ui)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile full build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) --profile full up --build -d
	@$(call _urls,full)

up-demo: ensure-llm ## Full stack + demo UI at / — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
ifdef USE_LOCAL
	@echo "→ Building from local sibling directories (../content-lake-app, ../alfresco-content-lake-ui, ../content-lake-app-ui)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
	  docker compose $(ENV_ARGS) --profile demo build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
	  docker compose $(ENV_ARGS) --profile demo up --build -d
	@$(call _urls,demo)

up-platform: ensure-llm ## Platform only (hxpr + RAG + demo UI), no Alfresco and no Nuxeo -- pair with --profile connector
	@echo "-> Bringing up the platform with no in-tree source. Add a connector jar and --profile connector to ingest."
ifdef USE_LOCAL
	@echo "-> Building from local sibling directories (../content-lake-app, ../content-lake-app-ui)..."
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=plugin-batch-ingester:9096 \
	  NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
	  docker compose $(ENV_ARGS) --profile platform build --no-cache
endif
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=plugin-batch-ingester:9096 \
	  NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
	  docker compose $(ENV_ARGS) --profile platform up --build -d
	@$(call _urls,platform)

down: ## Stop and remove containers (data volumes preserved)
	$(DC_ALL) --profile '*' down
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml down 2>/dev/null || true

logs: ## Follow logs for all running services
	$(DC_ALL) logs -f

ps: ## Show running services and health status
	$(DC_ALL) ps

config: ## Dry-run: render the resolved compose configuration
	$(LOAD_ENV) $(LOCAL_ENV_OVERRIDES) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) config

olmo3-local: ## Package Olmo 3 7B Instruct (the default LLM_MODEL) for Docker Model Runner
	scripts/package-olmo3-local.sh

ensure-llm: ## Package or pull LLM_MODEL if Docker Model Runner lacks it (run by every up-* target)
	@$(LOAD_ENV) scripts/ensure-llm-model.sh

start-ai: ## Start TEI + vLLM inference stack (prod, requires NVIDIA GPU)
	@$(LOAD_ENV) scripts/check-vllm-model.sh || true
	$(LOAD_ENV) docker compose -f compose.ai.yaml up -d

stop-ai: ## Stop TEI + vLLM inference stack
	$(LOAD_ENV) docker compose -f compose.ai.yaml down

clean: ## Stop containers and remove ALL volumes [DESTRUCTIVE — wipes all data]
	@echo "WARNING: This removes all persistent data (Alfresco, MongoDB, OpenSearch, etc.)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(DC_ALL) --profile '*' down -v
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml down -v 2>/dev/null || true

verify-profiles: ## Assert every opt-in profile stays opt-in (no service leaks into a base profile)
	@# An opt-in service that appears in a base profile is a silent dependency: every existing
	@# deployment would suddenly need it. Compose resolves profiles here, so this catches a missing or
	@# mistyped `profiles:` key that inspection would not.
	@fail=0; \
	for profile in alfresco nuxeo full demo platform; do \
	  services=$$($(DC) --profile $$profile config --services 2>/dev/null | sort | tr '\n' ' '); \
	  for optin in otel-lgtm plugin-batch-ingester opensearch-dashboards transform-liteparse transform-convert2md mock-graph; do \
	    case " $$services " in \
	      *" $$optin "*) echo "FAIL: $$optin is in the '$$profile' profile but should be opt-in only"; fail=1 ;; \
	    esac; \
	  done; \
	  echo "ok: profile '$$profile' has no opt-in service"; \
	done; \
	for pair in "observability:otel-lgtm" "connector:plugin-batch-ingester" "debug:opensearch-dashboards" "transform-extras:transform-liteparse" "sharepoint-mock:mock-graph"; do \
	  profile=$${pair%%:*}; service=$${pair##*:}; \
	  services=$$($(DC) --profile demo --profile $$profile config --services 2>/dev/null | tr '\n' ' '); \
	  case " $$services " in \
	    *" $$service "*) echo "ok: --profile $$profile adds $$service" ;; \
	    *) echo "FAIL: --profile $$profile does not add $$service"; fail=1 ;; \
	  esac; \
	done; \
	for profile in alfresco nuxeo full demo platform; do \
	  services=$$($(DC_ALL) --profile $$profile config --services 2>/dev/null | sort | tr '\n' ' '); \
	  for optin in $(ALFRESCO_2_SERVICES); do \
	    case " $$services " in \
	      *" $$optin "*) echo "FAIL: $$optin is in the '$$profile' profile with compose.alfresco-2.yaml loaded but should be opt-in only"; fail=1 ;; \
	    esac; \
	  done; \
	  echo "ok: profile '$$profile' has no alfresco-2 service with compose.alfresco-2.yaml loaded"; \
	done; \
	services=$$($(DC_ALL) --profile demo --profile alfresco-2 config --services 2>/dev/null | tr '\n' ' '); \
	for service in $(ALFRESCO_2_SERVICES); do \
	  case " $$services " in \
	    *" $$service "*) echo "ok: --profile alfresco-2 adds $$service" ;; \
	    *) echo "FAIL: --profile alfresco-2 does not add $$service"; fail=1 ;; \
	  esac; \
	done; \
	exit $$fail

# ── Internal ──────────────────────────────────────────────────────────────────

define _urls
	@set -a; . ./.env; if [ -f ./.env.local ]; then . ./.env.local; fi; set +a; \
	  if [ "$${USE_HTTPS:-false}" = "true" ]; then \
	    p="$${HTTPS_PORT:-443}"; \
	    base="https://$${SERVER_NAME:-localhost}"; \
	    [ "$$p" != "443" ] && base="$$base:$$p"; \
	  else \
	    p="$${PUBLIC_PORT:-80}"; \
	    base="http://$${SERVER_NAME:-localhost}"; \
	    [ "$$p" != "80" ] && base="$$base:$$p"; \
	  fi; \
	  echo ""; \
	  echo "Stack starting ($(1)). Endpoints once healthy:"; \
	  echo "  RAG API  → $$base/api/rag"; \
	  if [ "$(1)" = "platform" ]; then \
	    echo "  Demo UI  -> $$base/"; \
	    echo ""; \
	    echo "  No in-tree source in this profile. Mount a connector jar in ./connectors and add"; \
	    echo "  --profile connector to ingest. Signing in is not available yet: content-lake-app#167."; \
	    echo ""; \
	  else \
	    if [ "$(1)" != "nuxeo" ]; then \
	      echo "  ACA      → $$base/aca/"; \
	      echo "  Alfresco → $$base/alfresco"; \
	    fi; \
	    if [ "$(1)" = "alfresco-2" ]; then \
	      echo "  ACA 2      -> http://$${SERVER_NAME:-localhost}:$${ALFRESCO_2_PUBLIC_PORT:-8082}/aca/"; \
	      echo "  Alfresco 2 -> http://$${SERVER_NAME:-localhost}:$${ALFRESCO_2_PUBLIC_PORT:-8082}/alfresco"; \
	      echo ""; \
	      echo "  Once both are healthy, read each repository.id from /alfresco/api/discovery and set"; \
	      echo "  ALFRESCO_1_SOURCE_ID and ALFRESCO_2_SOURCE_ID, then run make up-alfresco-2 again."; \
	    elif [ "$(1)" != "alfresco" ]; then \
	      echo "  Nuxeo    → $$base/nuxeo/ui/"; \
	    fi; \
	    if [ "$(1)" = "demo" ]; then \
	      echo "  Demo UI  → $$base/"; \
	    fi; \
	  fi; \
	  echo ""
endef
