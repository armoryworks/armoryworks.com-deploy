#!/usr/bin/env bash
# setup-web.sh — First-time setup for armoryworks-web (the static-site box).
#
# Run after ./scripts/install-aw-deploy.sh.
#
# What it does:
#   1. Verifies prereqs + GHCR creds
#   2. Writes .env from .env.web.example if absent
#   3. Bootstraps UI_IMAGE_TAG=latest if blank
#   4. Warns if Cloudflare Origin Cert is missing
#   5. Pulls the latest published armory-works-ui image from GHCR
#   6. Creates + seeds the dynamic /writing content dir
#   7. Brings up the UI container on 127.0.0.1:4203
#
# Host nginx terminates TLS with the Cloudflare Origin Cert and proxies
# / → 127.0.0.1:4203 (this UI container).
#
# Run from /opt/armoryworks-deploy:
#   ./setup-web.sh

set -euo pipefail

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
    info "After installing, re-run:  ./setup-web.sh"
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
    docker compose -f docker-compose.web.yml "$@"
}

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║  Armory Works — Web box first-time setup     ║"
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
        bail "Docker (permissions)" "sudo usermod -aG docker \$USER (then newgrp docker)"
    else
        bail "Docker (daemon)" "sudo systemctl start docker"
    fi
fi
ok "$(docker --version 2>/dev/null)"

docker compose version >/dev/null 2>&1 || bail "Docker Compose v2" "sudo apt install -y docker-compose-plugin"
ok "$(docker compose version 2>/dev/null)"

if [[ ! -r /etc/armoryworks/ghcr-token ]]; then
    bail "GHCR credentials" \
        "Private GHCR images can't be pulled without 'docker login ghcr.io' first." \
        "Run: ./scripts/install-aw-deploy.sh   (it'll prompt for your GitHub PAT)"
fi
ok "GHCR credentials present"

UI_PORT=$(get_env UI_PORT)
UI_PORT=${UI_PORT:-4203}
if ss -tlnp 2>/dev/null | grep -q ":${UI_PORT} "; then
    warn "Port ${UI_PORT} (UI_PORT) is already in use on this host."
    info "Stop the listener or change UI_PORT in .env, then re-run."
    exit 1
fi
ok "Port ${UI_PORT} (UI_PORT) is available"

if [[ ! -d "/etc/letsencrypt/live/armoryworks.com.cloudflare" ]]; then
    warn "No Cloudflare Origin Cert at /etc/letsencrypt/live/armoryworks.com.cloudflare/"
    warn "Host nginx will fail TLS handshakes until you install one."
else
    ok "Cloudflare Origin Cert present for armoryworks.com"
fi

# ─────────────────────────────────────────────────────────────
# 2. Project files
# ─────────────────────────────────────────────────────────────

step "Verifying project files"

[[ -f "docker-compose.web.yml" ]] || { fail "docker-compose.web.yml not found — run from /opt/armoryworks-deploy."; exit 1; }
[[ -f ".env.web.example"      ]] || { fail ".env.web.example not found."; exit 1; }
ok "Project files found"

# ─────────────────────────────────────────────────────────────
# 3. .env
# ─────────────────────────────────────────────────────────────

step "Configuring environment"

if [[ ! -f .env ]]; then
    cp .env.web.example .env
    ok "Created .env from .env.web.example"
else
    ok ".env already exists"
fi

CURRENT_TAG=$(get_env UI_IMAGE_TAG)
if [[ -z "$CURRENT_TAG" ]]; then
    set_env "UI_IMAGE_TAG" "latest"
    warn "UI_IMAGE_TAG was empty — set to 'latest' for bootstrap."
    warn "Run 'aw-deploy --list' then 'aw-deploy main-<sha>' to pin an immutable tag."
fi

# ─────────────────────────────────────────────────────────────
# 4. Pull image
# ─────────────────────────────────────────────────────────────

step "Pulling armory-works-ui image from GHCR"
compose pull armory-works-ui
ok "UI image pulled"

# ─────────────────────────────────────────────────────────────
# 4b. Maintenance page (host nginx serves it when the UI is down)
# ─────────────────────────────────────────────────────────────

step "Installing maintenance page"
if [[ -f "ops/maintenance/maintenance.html" ]]; then
    sudo install -D -m 0644 ops/maintenance/maintenance.html /var/www/armoryworks-maintenance/maintenance.html
    ok "Installed /var/www/armoryworks-maintenance/maintenance.html"
    info "Host nginx serves this as a 503 when the UI container is unreachable"
    info "(error_page 502/503/504 in ops/nginx/armoryworks.com.conf)."
else
    warn "ops/maintenance/maintenance.html not found — skipping"
fi

# ─────────────────────────────────────────────────────────────
# 4c. Dynamic /writing content area (Tuyere writing CMS)
# ─────────────────────────────────────────────────────────────

step "Preparing dynamic /writing content dir"

WRITING_DIR=$(get_env WRITING_CONTENT_DIR)
WRITING_DIR=${WRITING_DIR:-/var/lib/armoryworks/writing}

sudo mkdir -p "$WRITING_DIR"
sudo chmod 0755 "$WRITING_DIR"
ok "Content dir ready: $WRITING_DIR"

# Seed a placeholder index so /writing/ serves a page before Tuyere publishes.
# The bind mount shadows the image's baked /writing, so without this the dir
# would be empty and /writing/ would 404. Tuyere overwrites this on publish.
if [[ ! -e "$WRITING_DIR/index.html" ]]; then
    sudo tee "$WRITING_DIR/index.html" >/dev/null <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Writing | Armory Works</title>
<link rel="stylesheet" href="/css/armoryworks.css">
</head>
<body>
<main class="container" style="padding:96px 0;">
<h1>Writing</h1>
<p>Operational notes are on the way.</p>
</main>
</body>
</html>
HTML
    sudo chmod 0644 "$WRITING_DIR/index.html"
    ok "Seeded placeholder /writing/index.html (Tuyere will overwrite it)"
else
    ok "/writing/index.html already present — leaving it"
fi

# Seed an empty 301 redirect map so the host-nginx `map … include` resolves
# before Tuyere has published any slug moves (nginx -t errors on a missing
# include file). Tuyere overwrites this on every publish.
if [[ ! -e "$WRITING_DIR/_redirects.map" ]]; then
    sudo touch "$WRITING_DIR/_redirects.map"
    sudo chmod 0644 "$WRITING_DIR/_redirects.map"
    ok "Seeded empty /writing/_redirects.map (Tuyere maintains it)"
else
    ok "/writing/_redirects.map already present — leaving it"
fi

info "Tuyere (co-hosted) needs WRITE access to $WRITING_DIR; the UI container"
info "mounts it read-only. Grant Tuyere's service user/group write when you"
info "wire up the Tuyere side."

# ─────────────────────────────────────────────────────────────
# 5. Start UI
# ─────────────────────────────────────────────────────────────

step "Starting UI container"
compose up -d --remove-orphans armory-works-ui

sleep 2

# ─────────────────────────────────────────────────────────────
# 6. Final status
# ─────────────────────────────────────────────────────────────

step "Container status"
compose ps

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo ""
echo "  ╔══════════════════════════════════════════════╗"
printf  "  ║          \033[32mWeb box setup complete!\033[0m              ║\n"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Host:    ${HOST_IP:-?}"
echo "  UI:      http://127.0.0.1:${UI_PORT}  (loopback only)"
echo "  Public:  https://armoryworks.com  (via Cloudflare Tunnel + host nginx)"
echo "  Tag:     $(get_env UI_IMAGE_TAG)"
echo "  Logs:    docker compose -f docker-compose.web.yml logs -f armory-works-ui"
echo "  Deploy:  aw-deploy --list   (see available tags)"
echo "           aw-deploy main-<sha>   (pin to an immutable tag)"
echo ""
echo "  ─── Host-level steps still required ───"
echo "  - Install host nginx vhost (serves the maintenance page installed above"
echo "    from /var/www/armoryworks-maintenance/ when the UI is unreachable):"
echo "      sudo cp ops/nginx/armoryworks.com.conf /etc/nginx/sites-available/"
echo "      sudo ln -s /etc/nginx/sites-available/armoryworks.com.conf /etc/nginx/sites-enabled/"
echo "      sudo nginx -t && sudo systemctl reload nginx"
echo "  - Install Cloudflare Origin Cert at /etc/letsencrypt/live/armoryworks.com.cloudflare/"
echo "  - Authenticate cloudflared and create the named tunnel"
echo ""
