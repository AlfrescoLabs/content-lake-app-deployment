#!/usr/bin/env bash
# =============================================================
# Content Lake — First-run setup script
# Validates prerequisites, pulls AI models,
# and starts the stack.
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

hdr "Content Lake setup — profile: $PROFILE"

# ── Check Docker ──────────────────────────────────────────────────────────────
hdr "1/5  Checking Docker..."
if ! docker info &>/dev/null; then
  err "Docker is not running. Start Docker Desktop and try again."
  exit 1
fi
ok "Docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown version'))"

# ── Check Docker Model Runner ─────────────────────────────────────────────────
hdr "2/5  Checking Docker Model Runner..."
if ! docker model list &>/dev/null; then
  err "Docker Model Runner is not available."
  echo "   Enable it in Docker Desktop → Settings → Features in development → Docker Model Runner"
  exit 1
fi
ok "Docker Model Runner is available"

# ── Pull AI models ────────────────────────────────────────────────────────────
hdr "3/5  Pulling AI models (skip if already present)..."
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
  hdr "4/5  Nuxeo prerequisite check..."
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
hdr "5/5  Starting Content Lake (profile: $PROFILE)..."
echo "   First build downloads and compiles Java source — allow 20–40 minutes."
echo "   Subsequent starts are fast (images are cached)."
echo ""
make "up-${PROFILE}"

echo ""
ok "Done! Use 'make ps' to check service health, 'make logs' to follow logs."
