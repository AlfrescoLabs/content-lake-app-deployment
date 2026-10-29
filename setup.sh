#!/usr/bin/env bash
# =============================================================
# Content Lake — First-run setup script
# Validates prerequisites, creates a local HTTPS cert when USE_HTTPS=true,
# pulls AI models, and starts the stack.
# Usage: ./setup.sh [alfresco|nuxeo|full|demo|platform]  (default: alfresco)
# =============================================================
set -euo pipefail

PROFILE="${1:-alfresco}"
VALID_PROFILES="alfresco nuxeo full demo platform"
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

err()  { echo -e "${RED}✗ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

# ── Validate profile ──────────────────────────────────────────────────────────
if ! echo "$VALID_PROFILES" | grep -qw "$PROFILE"; then
  err "Unknown profile '$PROFILE'. Choose: $VALID_PROFILES"
  exit 1
fi

# ── Load environment (same files and order as the Makefile) ───────────────────
cd "$(dirname "$0")"
if [ ! -f ./.env ]; then
  err ".env not found in $(pwd)."
  exit 1
fi
set -a
# shellcheck source=/dev/null
. ./.env
if [ -f ./.env.local ]; then
  # shellcheck source=/dev/null
  . ./.env.local
fi
set +a

hdr "Content Lake setup — profile: $PROFILE"

# ── Check Docker ──────────────────────────────────────────────────────────────
hdr "1/6  Checking Docker..."
if ! docker info &>/dev/null; then
  err "Docker is not running. Start Docker Desktop and try again."
  exit 1
fi
ok "Docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown version'))"

# Optional: set DOCKER_REGISTRY_LOGIN (in .env or .env.local) to a registry host to log into it first,
# for example a private mirror that hosts the base images.
if [ -n "${DOCKER_REGISTRY_LOGIN:-}" ]; then
  echo "   Logging into $DOCKER_REGISTRY_LOGIN..."
  echo "   Keep this terminal open while completing any credential or GPG unlock prompt."
  docker login "$DOCKER_REGISTRY_LOGIN"
  ok "Logged into $DOCKER_REGISTRY_LOGIN"
fi

# ── Check local HTTPS certificate ─────────────────────────────────────────────
HTTPS_CERT_GENERATED=0
if [ "${USE_HTTPS:-false}" = "true" ]; then
  hdr "2/6  Checking local HTTPS certificate..."
  if [ -f nginx/certs/local/server.crt ] && [ -f nginx/certs/local/server.key ]; then
    ok "Local HTTPS certificate already present (nginx/certs/local)"
  else
    if ! command -v openssl &>/dev/null; then
      err "USE_HTTPS=true needs openssl to generate the local certificate, but it is not installed."
      echo "   Ubuntu/Debian (including WSL):"
      echo "     sudo apt-get update"
      echo "     sudo apt-get install -y openssl"
      echo "     openssl version"
      echo "   Then re-run this script, or set USE_HTTPS=false in .env.local to stay on HTTP."
      exit 1
    fi
    cert_dir=""
    if [ -d nginx/certs/local ]; then
      cert_dir="nginx/certs/local"
    elif [ -d nginx/certs ]; then
      cert_dir="nginx/certs"
    fi
    if [ -n "$cert_dir" ] && [ ! -w "$cert_dir" ]; then
      err "$cert_dir is not writable by $(id -un); an earlier Docker run probably created it as root."
      echo "   Give it back to your user, then re-run this script:"
      echo "     sudo chown -R $(id -u):$(id -g) nginx/certs"
      exit 1
    fi
    bash scripts/generate-local-cert.sh >/dev/null
    HTTPS_CERT_GENERATED=1
    ok "Local HTTPS certificate generated (nginx/certs/local)"
  fi
fi

# ── Check Docker Model Runner ─────────────────────────────────────────────────
hdr "3/6  Checking Docker Model Runner..."
if ! docker model list &>/dev/null; then
  err "Docker Model Runner is not available."
  echo "   Enable it in Docker Desktop → Settings → Features in development → Docker Model Runner"
  echo "   WSL with Docker Engine (Ubuntu/Debian):"
  echo "     sudo apt-get update"
  echo "     sudo apt-get install docker-model-plugin"
  echo "     docker model version"
  echo "   Docs: https://docs.docker.com/ai/model-runner/get-started/#docker-engine"
  echo "   For GPU-accelerated inference, configure GPU support for your container runtime and host system."
  exit 1
fi
ok "Docker Model Runner is available"

# ── Pull AI models ────────────────────────────────────────────────────────────
hdr "4/6  Pulling AI models (skip if already present)..."

# Behind a TLS-inspecting proxy, the Model Runner container must trust the proxy's CA to pull models.
# Opt-in: set MODEL_RUNNER_CA_BUNDLE to a CA bundle on the host. The container name defaults to
# docker-model-runner (override with MODEL_RUNNER_CONTAINER).
if [ -n "${MODEL_RUNNER_CA_BUNDLE:-}" ]; then
  CA_BUNDLE="$MODEL_RUNNER_CA_BUNDLE"
  RUNNER_CONTAINER="${MODEL_RUNNER_CONTAINER:-docker-model-runner}"
  if [ ! -f "$CA_BUNDLE" ]; then
    warn "MODEL_RUNNER_CA_BUNDLE is set but $CA_BUNDLE does not exist; skipping CA bundle injection."
  elif docker inspect "$RUNNER_CONTAINER" &>/dev/null; then
    if ! docker exec "$RUNNER_CONTAINER" cat /etc/ssl/certs/ca-certificates.crt 2>/dev/null | cmp -s - "$CA_BUNDLE"; then
      echo "   Injecting CA bundle into $RUNNER_CONTAINER..."
      docker cp "$CA_BUNDLE" "$RUNNER_CONTAINER:/etc/ssl/certs/ca-certificates.crt"
      docker restart "$RUNNER_CONTAINER" >/dev/null
      for _ in $(seq 1 30); do
        docker model list &>/dev/null && break
        sleep 1
      done
    fi
  else
    warn "Model Runner container '$RUNNER_CONTAINER' not found; skipping CA bundle injection."
  fi
fi
for model in ai/mxbai-embed-large; do
  if docker model inspect "$model" &>/dev/null; then
    ok "$model already present"
  else
    echo "   Pulling $model (this may take a few minutes)..."
    docker model pull "$model"
    ok "$model pulled"
  fi
done
( set -a; . ./.env; if [ -f .env.local ]; then . ./.env.local; fi; set +a
  scripts/ensure-llm-model.sh && ok "LLM_MODEL ${LLM_MODEL} ready" )

# ── Nuxeo prerequisite ────────────────────────────────────────────────────────
if [[ "$PROFILE" == "nuxeo" || "$PROFILE" == "full" || "$PROFILE" == "demo" ]]; then
  hdr "5/6  Nuxeo prerequisite check..."
  NUXEO_DIR="../nuxeo-deployment"
  if [ ! -d "$NUXEO_DIR" ]; then
    warn "Nuxeo server not found at $NUXEO_DIR"
    echo "   Clone it with:"
    echo "     git clone https://github.com/aborroy/nuxeo-deployment.git $NUXEO_DIR"
    echo "   Then re-run this script."
    exit 1
  fi
  echo "   Starting Nuxeo (first build takes 30–60 min)..."
  docker compose -f "$NUXEO_DIR/compose.yaml" up -d
  ok "Nuxeo server starting (check logs: docker compose -f $NUXEO_DIR/compose.yaml logs -f)"
fi

# ── Start the stack ───────────────────────────────────────────────────────────
hdr "6/6  Starting Content Lake (profile: $PROFILE)..."
echo "   First build downloads and compiles Java source — allow 20–40 minutes."
echo "   Subsequent starts are fast (images are cached)."
echo ""
make "up-${PROFILE}"

# A proxy that was already running without a certificate stripped its HTTPS block at
# startup and is not recreated by compose, so restart it to load the new certificate.
if [ "$HTTPS_CERT_GENERATED" = "1" ]; then
  proxy_ids=$(docker ps -q \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-content-lake-app}" \
    --filter "label=com.docker.compose.service=proxy")
  if [ -n "$proxy_ids" ]; then
    echo "   Restarting the proxy so it loads the new certificate..."
    echo "$proxy_ids" | xargs docker restart >/dev/null
    ok "Proxy restarted with HTTPS"
  fi
fi

echo ""
ok "Done! Use 'make ps' to check service health, 'make logs' to follow logs."
