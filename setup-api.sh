#!/usr/bin/env bash
# setup-api.sh — First-time setup for armoryworks-api (the .NET API + Postgres).
#
# Run after ./scripts/install-aw-deploy.sh.
#
# What it does:
#   1. Verifies prereqs (Docker, compose, curl, jq) + GHCR creds present
#   2. Generates POSTGRES_PASSWORD if blank
#   3. Bootstraps SERVER_IMAGE_TAG=latest if blank
#   4. Pulls the latest published armory-works-server image from GHCR
#   5. Brings up Postgres + waits for healthy
#   6. Brings up the server container
#   7. Waits for healthy
#
# Migrations run automatically: the api image ships a self-contained
# `dotnet ef migrations bundle` executable at /app/efbundle, generated
# at image-build time. setup-api.sh runs it between the db-up and
# server-up steps. aw-deploy does the same on every subsequent deploy.
#
# Run from /opt/armoryworks-deploy:
#   ./setup-api.sh
#
# Options:
#   --fresh   Drop the database volume and start over.

set -euo pipefail

FRESH=false

for arg in "$@"; do
    case $arg in
        --fresh) FRESH=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

step()  { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m[!!] %s\033[0m\n' "$1"; }
fail()  { printf '    \033[31m[X]  %s\033[0m\n' "$1"; }
info()  { printf '         %s\n' "$1"; }

bail() {
    echo ""; fail "Missing prerequisite: $1"; echo ""
    shift
    for line in "$@"; do info "$line"; done
    echo ""
    info "After installing, re-run:  ./setup-api.sh"
    echo ""
    exit 1
}

set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}

get_env() {
    local key="$1"
    [[ -f .env ]] || return 0
    local line val
    line=$(grep "^${key}=" .env 2>/dev/null | tail -n 1 || true)
    [[ -z "$line" ]] && return 0
    val="${line#*=}"
    if [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
        val="${val:1:${#val}-2}"
    elif [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
        val="${val:1:${#val}-2}"
    fi
    printf '%s' "$val"
}

compose() {
    docker compose -f docker-compose.api.yml "$@"
}

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║  Armory Works — API box first-time setup     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. Prereqs
# ─────────────────────────────────────────────────────────────

step "Checking prerequisites"

command -v docker >/dev/null 2>&1 || bail "Docker" "Install from https://docs.docker.com/engine/install/"
command -v curl   >/dev/null 2>&1 || bail "curl"   "sudo apt install -y curl"
command -v jq     >/dev/null 2>&1 || bail "jq"     "sudo apt install -y jq"

if ! docker info >/dev/null 2>&1; then
    if docker info 2>&1 | grep -qi "permission denied"; then
        bail "Docker (permissions)" \
            "Your user cannot access the docker socket." \
            "Run: sudo usermod -aG docker \$USER  (then newgrp docker or log out/in)"
    else
        bail "Docker (daemon)" "sudo systemctl start docker"
    fi
fi
ok "$(docker --version 2>/dev/null)"

docker compose version >/dev/null 2>&1 || bail "Docker Compose v2" "sudo apt install -y docker-compose-plugin"
ok "$(docker compose version 2>/dev/null)"

# GHCR auth must already be configured (private images can't pull anonymously).
if [[ ! -r /etc/armoryworks/ghcr-token ]]; then
    bail "GHCR credentials" \
        "Private GHCR images can't be pulled without 'docker login ghcr.io' first." \
        "Run: ./scripts/install-aw-deploy.sh   (it'll prompt for your GitHub PAT)"
fi
ok "GHCR credentials present"

API_PORT=$(get_env API_PORT)
API_PORT=${API_PORT:-8203}
if ss -tlnp 2>/dev/null | grep -q ":${API_PORT} "; then
    warn "Port ${API_PORT} (API_PORT) is already in use."
    info "Stop the listener or change API_PORT in .env, then re-run."
    exit 1
fi
ok "Port ${API_PORT} (API_PORT) is available"

# ─────────────────────────────────────────────────────────────
# 2. Project files
# ─────────────────────────────────────────────────────────────

step "Verifying project files"

[[ -f "docker-compose.api.yml" ]] || { fail "docker-compose.api.yml not found — run from /opt/armoryworks-deploy."; exit 1; }
[[ -f ".env.api.example"      ]] || { fail ".env.api.example not found."; exit 1; }
ok "Project files found"

# ─────────────────────────────────────────────────────────────
# 3. .env
# ─────────────────────────────────────────────────────────────

step "Configuring environment"

if [[ ! -f .env ]]; then
    cp .env.api.example .env
    ok "Created .env from .env.api.example"
fi

CURRENT_PG_PASS=$(get_env POSTGRES_PASSWORD)
if [[ -z "$CURRENT_PG_PASS" ]]; then
    PG_PASS=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 || true)
    set_env "POSTGRES_PASSWORD" "$PG_PASS"
    ok "Generated random POSTGRES_PASSWORD (32 chars, alnum)"
    warn "Stash this in 1Password — there is no recovery path if .env is lost."
    info "POSTGRES_PASSWORD=$PG_PASS"
else
    ok "POSTGRES_PASSWORD already set in .env"
fi

CURRENT_TAG=$(get_env SERVER_IMAGE_TAG)
if [[ -z "$CURRENT_TAG" ]]; then
    set_env "SERVER_IMAGE_TAG" "latest"
    warn "SERVER_IMAGE_TAG was empty — set to 'latest' for bootstrap."
    warn "Run 'aw-deploy --list' then 'aw-deploy main-<sha>' to pin an immutable tag."
fi

MISSING=""
for key in EMAIL_SMTP_HOST EMAIL_SMTP_USER EMAIL_SMTP_PASSWORD OIDC_CLIENT_SECRET; do
    val=$(get_env "$key")
    [[ -z "$val" ]] && MISSING="${MISSING} $key"
done
if [[ -n "$MISSING" ]]; then
    warn "These env vars are still blank — fill them before the cutover:${MISSING}"
fi

# ─────────────────────────────────────────────────────────────
# 4. Fresh — drop volumes
# ─────────────────────────────────────────────────────────────

if $FRESH; then
    step "Wiping database volume (--fresh)"
    compose down -v 2>/dev/null || true
    ok "Volume dropped"
fi

# ─────────────────────────────────────────────────────────────
# 5. Pull image
# ─────────────────────────────────────────────────────────────

step "Pulling armory-works-server image from GHCR"
compose pull armory-works-server
ok "Server image pulled"

# ─────────────────────────────────────────────────────────────
# 6. Start DB
# ─────────────────────────────────────────────────────────────

step "Starting database"
compose up -d armory-works-db

ELAPSED=0
while (( ELAPSED < 60 )); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' armory-works-db 2>/dev/null || echo "unknown")
    [[ "$STATUS" == "healthy" ]] && break
    printf "\r    Waiting for Postgres... %s (%ds)" "$STATUS" "$ELAPSED"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo ""
if [[ "$STATUS" != "healthy" ]]; then
    fail "Postgres did not become healthy in 60s — check: docker compose -f docker-compose.api.yml logs armory-works-db"
    exit 1
fi
ok "Database is healthy"

# ─────────────────────────────────────────────────────────────
# 7. EF migrations
# ─────────────────────────────────────────────────────────────
#
# The api image carries a self-contained migrations bundle at /app/efbundle
# built into the image via `dotnet ef migrations bundle --self-contained`.
# Run it now against the running DB before starting the server, so the
# schema is in place when the API container boots.

step "Applying EF migrations"

PG_DB=$(get_env POSTGRES_DB)
PG_USER=$(get_env POSTGRES_USER)
PG_PASS=$(get_env POSTGRES_PASSWORD)
PG_DB=${PG_DB:-armory_works_db}
PG_USER=${PG_USER:-postgres}

if [[ -z "$PG_PASS" ]]; then
    fail "POSTGRES_PASSWORD not set in .env — cannot run migrations"
    exit 1
fi

NETWORK=$(docker network ls --format '{{.Name}}' | grep -E '^armory-works-api_' | head -1)
if [[ -z "$NETWORK" ]]; then
    fail "Compose network armory-works-api_* not found — is armory-works-db up?"
    exit 1
fi

DB_CONN="Host=armory-works-db;Port=5432;Database=${PG_DB};Username=${PG_USER};Password=${PG_PASS}"
CURRENT_TAG=$(get_env SERVER_IMAGE_TAG)
CURRENT_TAG=${CURRENT_TAG:-latest}
SERVER_IMAGE="ghcr.io/armoryworks/armory-works-server:${CURRENT_TAG}"

if ! docker run --rm \
        --network "$NETWORK" \
        --entrypoint /app/efbundle \
        "$SERVER_IMAGE" \
        --connection "$DB_CONN"; then
    fail "EF migration failed — server NOT started. Fix the migration and re-run setup-api.sh."
    exit 1
fi
ok "Migrations applied"

# ─────────────────────────────────────────────────────────────
# 8. Start server
# ─────────────────────────────────────────────────────────────

step "Starting API server"
compose up -d --remove-orphans armory-works-server

# ─────────────────────────────────────────────────────────────
# 8. Wait for API health
# ─────────────────────────────────────────────────────────────

step "Waiting for API to become healthy"

MAX_WAIT=120
ELAPSED=0
HEALTHY=false
while (( ELAPSED < MAX_WAIT )); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' armory-works-server 2>/dev/null || echo "unknown")
    [[ "$STATUS" == "healthy" ]] && { HEALTHY=true; break; }
    printf "\r    API status: %s (%ds / %ds)" "$STATUS" "$ELAPSED" "$MAX_WAIT"
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done
echo ""
if $HEALTHY; then
    ok "API is healthy"
else
    warn "API health check timed out after ${MAX_WAIT}s"
    warn "Check: docker compose -f docker-compose.api.yml logs -f armory-works-server"
fi

# ─────────────────────────────────────────────────────────────
# 9. Final status
# ─────────────────────────────────────────────────────────────

step "Container status"
compose ps

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo ""
echo "  ╔══════════════════════════════════════════════╗"
printf  "  ║          \033[32mAPI box setup complete!\033[0m              ║\n"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Host:    ${HOST_IP:-?}"
echo "  API:     http://${HOST_IP:-?}:${API_PORT}/api/health"
echo "  Tag:     $(get_env SERVER_IMAGE_TAG)"
echo "  Logs:    docker compose -f docker-compose.api.yml logs -f armory-works-server"
echo "  Deploy:  aw-deploy --list   (see available tags)"
echo "           aw-deploy main-<sha>   (pin to an immutable tag)"
echo ""
echo "  ─── Reminders ───"
echo "  - UFW allow API LAN-only:"
echo "      sudo ufw allow from 192.168.1.0/24 to any port ${API_PORT} proto tcp comment 'API LAN only'"
echo "  - Fill SMTP credentials + OIDC_CLIENT_SECRET in .env before cutover."
echo "  - Migrations run automatically on every aw-deploy via the bundled"
echo "    /app/efbundle in the api image. Schema changes are zero-touch."
echo ""
