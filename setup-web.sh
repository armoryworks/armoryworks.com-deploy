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
    # Tolerate the expected case on a re-run: the port is held by our own
    # armory-works-ui container that an earlier deploy already brought up.
    PORT_OCCUPANT=$(docker ps --filter "publish=${UI_PORT}" --format '{{.Names}}' 2>/dev/null | head -1)
    if [[ "$PORT_OCCUPANT" == "armory-works-ui" ]]; then
        ok "Port ${UI_PORT} held by the existing armory-works-ui container — leaving it"
    else
        warn "Port ${UI_PORT} (UI_PORT) is already in use on this host${PORT_OCCUPANT:+ (container '${PORT_OCCUPANT}')}."
        info "Stop the listener or change UI_PORT in .env, then re-run."
        info "Diagnostic:  sudo ss -tlnp 'sport = :${UI_PORT}'"
        exit 1
    fi
else
    ok "Port ${UI_PORT} (UI_PORT) is available"
fi

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
# 3b. Receiver bind + bearer token — set BEFORE any `compose` call,
#     because docker compose validates the WHOLE file (including the
#     ${WRITING_RECEIVER_TOKEN:?} on tuyere-writing-receiver) even when
#     you only act on one service.
# ─────────────────────────────────────────────────────────────

step "Configuring receiver bind + token in .env"

DETECTED_LAN_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)

# Bind: env var > existing non-default .env value > auto-detected LAN IP.
if [[ -n "${WRITING_RECEIVER_BIND:-}" ]]; then
    set_env WRITING_RECEIVER_BIND "$WRITING_RECEIVER_BIND"
    ok "WRITING_RECEIVER_BIND=$WRITING_RECEIVER_BIND (from environment)"
else
    CURRENT_BIND=$(get_env WRITING_RECEIVER_BIND)
    if [[ -z "$CURRENT_BIND" || "$CURRENT_BIND" == "127.0.0.1" ]]; then
        if [[ -n "$DETECTED_LAN_IP" ]]; then
            set_env WRITING_RECEIVER_BIND "$DETECTED_LAN_IP"
            ok "WRITING_RECEIVER_BIND=$DETECTED_LAN_IP (auto-detected)"
        else
            warn "Couldn't auto-detect a LAN IP — set WRITING_RECEIVER_BIND in .env manually."
        fi
    else
        ok "WRITING_RECEIVER_BIND=$CURRENT_BIND (preserving .env value)"
    fi
fi

# Token: env var > existing non-placeholder .env > interactive prompt > generate.
is_placeholder_token() {
    case "$1" in
        ""|"change-me"*|"<paste"*|"PASTE"*) return 0 ;;
        *) return 1 ;;
    esac
}

ENV_TOKEN="${WRITING_RECEIVER_TOKEN:-}"
EXISTING_TOKEN=$(get_env WRITING_RECEIVER_TOKEN)

if [[ -n "$ENV_TOKEN" ]] && ! is_placeholder_token "$ENV_TOKEN"; then
    set_env WRITING_RECEIVER_TOKEN "$ENV_TOKEN"
    CURRENT_TOKEN="$ENV_TOKEN"
    ok "WRITING_RECEIVER_TOKEN: using value from environment"
elif ! is_placeholder_token "$EXISTING_TOKEN"; then
    CURRENT_TOKEN="$EXISTING_TOKEN"
    ok "WRITING_RECEIVER_TOKEN: reusing value already in .env"
elif [[ -t 0 ]]; then
    echo ""
    info "WRITING_RECEIVER_TOKEN is the shared bearer tuyere-api uses to authenticate"
    info "to the receiver. It must match the value on the API box (paste it on both)."
    read -r -p "    Paste an existing token, or press Enter to auto-generate: " ENTERED_TOKEN
    if [[ -n "$ENTERED_TOKEN" ]]; then
        CURRENT_TOKEN="$ENTERED_TOKEN"
        set_env WRITING_RECEIVER_TOKEN "$CURRENT_TOKEN"
        ok "WRITING_RECEIVER_TOKEN: saved your pasted value to .env"
    else
        CURRENT_TOKEN=$(openssl rand -hex 24)
        set_env WRITING_RECEIVER_TOKEN "$CURRENT_TOKEN"
        ok "WRITING_RECEIVER_TOKEN: generated a new value"
    fi
else
    CURRENT_TOKEN=$(openssl rand -hex 24)
    set_env WRITING_RECEIVER_TOKEN "$CURRENT_TOKEN"
    ok "WRITING_RECEIVER_TOKEN: generated a new value (no TTY for prompt)"
fi

RECEIVER_PORT=$(get_env WRITING_RECEIVER_PORT); RECEIVER_PORT=${RECEIVER_PORT:-5103}
RECEIVER_URL="http://${DETECTED_LAN_IP:-<WEB-LAN-IP>}:${RECEIVER_PORT}"

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

# The tuyere-writing-receiver container writes here as its image's non-root
# user (.NET aspnet image: uid 1654). nginx in the armory-works-ui container
# reads it via the RO mount; world-readable (a+rX) covers both.
RECEIVER_UID="${WRITING_RECEIVER_UID:-1654}"
sudo chown -R "$RECEIVER_UID":"$RECEIVER_UID" "$WRITING_DIR"
sudo chmod -R a+rX "$WRITING_DIR"
ok "Ownership: uid $RECEIVER_UID writes; UI nginx reads (world-readable)"

# ─────────────────────────────────────────────────────────────
# 4e. Host nginx vhost — install, validate, reload (idempotent)
# ─────────────────────────────────────────────────────────────

step "Installing host nginx vhost"

VHOST_SRC="ops/nginx/armoryworks.com.conf"
VHOST_TARGET=/etc/nginx/sites-available/armoryworks.com.conf
VHOST_LINK=/etc/nginx/sites-enabled/armoryworks.com.conf

if [[ ! -f "$VHOST_SRC" ]]; then
    fail "missing $VHOST_SRC (did 'git pull' run in this repo?)"
    exit 1
fi
if ! sudo cmp -s "$VHOST_SRC" "$VHOST_TARGET" 2>/dev/null; then
    sudo install -m 0644 "$VHOST_SRC" "$VHOST_TARGET"
    ok "Installed $VHOST_TARGET"
else
    ok "vhost already up to date"
fi
[[ -L "$VHOST_LINK" || -e "$VHOST_LINK" ]] || sudo ln -s "$VHOST_TARGET" "$VHOST_LINK"

if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
    ok "nginx -t OK, reloaded"
else
    fail "nginx -t FAILED — fix the vhost before continuing"
    sudo nginx -t
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 4f. writing-reload systemd service — install + enable
# ─────────────────────────────────────────────────────────────

step "Installing writing-reload systemd service"

if ! command -v inotifywait >/dev/null 2>&1; then
    info "inotify-tools not installed — installing"
    sudo apt-get install -y inotify-tools
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
RELOAD_SH="$REPO_DIR/ops/writing-reload.sh"
RELOAD_UNIT=/etc/systemd/system/armoryworks-writing-reload.service

sudo chmod +x "$RELOAD_SH"

WANT_UNIT=$(cat <<UNIT
[Unit]
Description=Reload nginx when the Tuyere writing redirect map changes
After=nginx.service

[Service]
Environment=WRITING_CONTENT_DIR=$WRITING_DIR
ExecStart=$RELOAD_SH
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
)

if [[ "$(sudo cat "$RELOAD_UNIT" 2>/dev/null || true)" != "$WANT_UNIT" ]]; then
    echo "$WANT_UNIT" | sudo tee "$RELOAD_UNIT" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now armoryworks-writing-reload
    ok "Installed + started armoryworks-writing-reload"
else
    sudo systemctl is-active --quiet armoryworks-writing-reload \
        && ok "armoryworks-writing-reload already active" \
        || { sudo systemctl enable --now armoryworks-writing-reload; ok "(Re)started armoryworks-writing-reload"; }
fi

# ─────────────────────────────────────────────────────────────
# 4g. UFW — restrict the receiver port to the API box's source
# ─────────────────────────────────────────────────────────────

step "Configuring UFW for the receiver port"

# Env var takes precedence over .env, then persists to .env for future runs.
if [[ -n "${WRITING_RECEIVER_ALLOW_FROM:-}" ]]; then
    set_env WRITING_RECEIVER_ALLOW_FROM "$WRITING_RECEIVER_ALLOW_FROM"
fi
API_BOX_IP_ALLOW=$(get_env WRITING_RECEIVER_ALLOW_FROM)
if [[ -n "$API_BOX_IP_ALLOW" ]] && command -v ufw >/dev/null 2>&1; then
    sudo ufw allow from "$API_BOX_IP_ALLOW" to any port "$RECEIVER_PORT" proto tcp comment 'tuyere-writing-receiver' >/dev/null
    ok "UFW: allow from $API_BOX_IP_ALLOW to port $RECEIVER_PORT"
elif [[ -z "$API_BOX_IP_ALLOW" ]]; then
    info "Set WRITING_RECEIVER_ALLOW_FROM=<api-box-ip> in .env to auto-install the UFW rule."
else
    warn "ufw not installed — skipping firewall rule"
fi

# ─────────────────────────────────────────────────────────────
# 4h. Pull + bring up tuyere-writing-receiver
# ─────────────────────────────────────────────────────────────

step "Bringing up tuyere-writing-receiver"
compose pull tuyere-writing-receiver
compose up -d tuyere-writing-receiver
sleep 1
if curl -fsS "http://${DETECTED_LAN_IP:-127.0.0.1}:${RECEIVER_PORT}/health" >/dev/null 2>&1; then
    ok "Receiver healthy at http://${DETECTED_LAN_IP:-127.0.0.1}:${RECEIVER_PORT}"
else
    warn "Receiver started but /health not responding yet — check 'docker logs tuyere-writing-receiver'"
fi

cat <<EOF

═══════════════════════════════════════════════════════════════════════
Paste THIS on the API box, in the tuyere-deploy directory, to wire
tuyere-api to this receiver. Run it BEFORE \`./deploy.sh --role api\`.
═══════════════════════════════════════════════════════════════════════

  mkdir -p secrets
  cat >> secrets/tuyere.env <<'AWT_RECEIVER'
WRITING_RECEIVER_BASE_URL=$RECEIVER_URL
WRITING_RECEIVER_TOKEN=$CURRENT_TOKEN
AWT_RECEIVER

═══════════════════════════════════════════════════════════════════════
EOF

# ─────────────────────────────────────────────────────────────
# 4i. tuyere.armoryworks.com nginx vhost (idempotent)
#     Without this, requests to tuyere.armoryworks.com hit the default 443
#     server (the www -> apex redirect) and bounce to armoryworks.com.
#     Requires the Cloudflare Origin Cert files to be present.
# ─────────────────────────────────────────────────────────────

step "Installing tuyere.armoryworks.com nginx vhost"

TUYERE_VHOST_TARGET=/etc/nginx/sites-available/tuyere.armoryworks.com.conf
TUYERE_VHOST_LINK=/etc/nginx/sites-enabled/tuyere.armoryworks.com.conf
TUYERE_CERT_DIR=/etc/letsencrypt/live/tuyere.armoryworks.com.cloudflare

if [[ ! -f "$TUYERE_CERT_DIR/fullchain.pem" ]]; then
    warn "Cloudflare Origin Cert missing at $TUYERE_CERT_DIR/ — skipping tuyere vhost"
    warn "  Install it first:"
    warn "    Cloudflare dashboard -> armoryworks.com -> SSL/TLS -> Origin Server"
    warn "    -> Create Certificate (hostname: tuyere.armoryworks.com, validity 15y)"
    warn "  Then on this box:"
    warn "    sudo mkdir -p $TUYERE_CERT_DIR"
    warn "    sudo nano $TUYERE_CERT_DIR/fullchain.pem      # paste the cert"
    warn "    sudo nano $TUYERE_CERT_DIR/privkey.pem        # paste the key"
    warn "    sudo chmod 600 $TUYERE_CERT_DIR/privkey.pem"
    warn "  Then re-run ./setup-web.sh."
elif [[ -z "${API_BOX_IP_ALLOW:-}" ]]; then
    warn "WRITING_RECEIVER_ALLOW_FROM missing — can't render tuyere vhost (needs API box IP)"
else
    NEW_VHOST=$(cat <<CONF
# Host nginx vhost for tuyere.armoryworks.com (managed by setup-web.sh).
# TLS terminates here (Cloudflare Origin Cert); inbound is Cloudflare Tunnel.
# /     -> local tuyere-admin-ui SPA (127.0.0.1:5101; future)
# /api  -> tuyere-api on the API box LAN (${API_BOX_IP_ALLOW}:5100)

server {
    listen 127.0.0.1:443 ssl;
    listen [::1]:443 ssl;
    http2 on;
    server_name tuyere.armoryworks.com;

    ssl_certificate     $TUYERE_CERT_DIR/fullchain.pem;
    ssl_certificate_key $TUYERE_CERT_DIR/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:MozSSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                             always;
    add_header X-Frame-Options           "DENY"                                always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin"     always;

    client_max_body_size 2m;

    location /api/ {
        proxy_pass http://${API_BOX_IP_ALLOW}:5100;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:5101;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF
)
    if [[ "$(sudo cat "$TUYERE_VHOST_TARGET" 2>/dev/null || true)" != "$NEW_VHOST" ]]; then
        echo "$NEW_VHOST" | sudo tee "$TUYERE_VHOST_TARGET" >/dev/null
        ok "Installed $TUYERE_VHOST_TARGET (API box: ${API_BOX_IP_ALLOW})"
    else
        ok "tuyere vhost already up to date"
    fi
    [[ -L "$TUYERE_VHOST_LINK" || -e "$TUYERE_VHOST_LINK" ]] || sudo ln -s "$TUYERE_VHOST_TARGET" "$TUYERE_VHOST_LINK"

    if sudo nginx -t >/dev/null 2>&1; then
        # `reload` (SIGHUP) sometimes won't replace workers when a NEW
        # server_name on an existing listen address is added; full restart
        # guarantees the new server block is live.
        sudo systemctl restart nginx
        ok "nginx -t OK, restarted (new server block requires restart, not reload)"
    else
        fail "nginx -t FAILED on tuyere vhost"
        sudo nginx -t
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────
# 4j. Cloudflared tunnel ingress for tuyere.armoryworks.com
#     (idempotent: skips if already wired; YAML-edited, not sed-hacked)
# ─────────────────────────────────────────────────────────────

step "Wiring cloudflared ingress for tuyere.armoryworks.com"

if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared not installed on this host — skipping tunnel automation"
else
    CFD_CONFIG=""
    for c in /etc/cloudflared/config.yml /etc/cloudflared/config.yaml \
             "$(cd "$(dirname "$0")" && pwd)/ops/cloudflared/config.yml" \
             "$HOME/.cloudflared/config.yml"; do
        [[ -f "$c" ]] && { CFD_CONFIG="$c"; break; }
    done

    if [[ -z "$CFD_CONFIG" ]]; then
        warn "cloudflared config not found in /etc/cloudflared/, ops/cloudflared/, or ~/.cloudflared/ — add the tuyere.armoryworks.com ingress manually"
    elif sudo grep -q 'tuyere\.armoryworks\.com' "$CFD_CONFIG"; then
        ok "cloudflared ingress already includes tuyere.armoryworks.com ($CFD_CONFIG)"
    else
        # Need a YAML-aware editor. Prefer yq; fall back to python3 + PyYAML.
        if ! command -v yq >/dev/null 2>&1 && ! python3 -c "import yaml" 2>/dev/null; then
            info "Installing python3-yaml for safe YAML editing"
            sudo apt-get install -y python3-yaml >/dev/null
        fi
        if command -v yq >/dev/null 2>&1; then
            sudo yq -i '.ingress = [{"hostname":"tuyere.armoryworks.com","service":"https://127.0.0.1:443","originRequest":{"noTLSVerify":true}}] + (.ingress // [])' "$CFD_CONFIG"
        else
            sudo python3 - "$CFD_CONFIG" <<'PY'
import yaml, sys
p = sys.argv[1]
with open(p) as f: cfg = yaml.safe_load(f) or {}
ingress = cfg.setdefault('ingress', [])
ingress.insert(0, {'hostname': 'tuyere.armoryworks.com', 'service': 'https://127.0.0.1:443', 'originRequest': {'noTLSVerify': True}})
with open(p, 'w') as f: yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY
        fi
        ok "added tuyere.armoryworks.com ingress to $CFD_CONFIG"
    fi

    # DNS route — cloudflared itself is idempotent here.
    TUNNEL_NAME=$(sudo grep -E '^tunnel:' "$CFD_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1 || echo "")
    if [[ -n "$TUNNEL_NAME" ]]; then
        if sudo cloudflared tunnel route dns "$TUNNEL_NAME" tuyere.armoryworks.com >/dev/null 2>&1 \
           || cloudflared tunnel route dns "$TUNNEL_NAME" tuyere.armoryworks.com >/dev/null 2>&1; then
            ok "DNS route ensured: tuyere.armoryworks.com -> $TUNNEL_NAME"
        else
            warn "cloudflared DNS route command failed — run manually: cloudflared tunnel route dns $TUNNEL_NAME tuyere.armoryworks.com"
        fi
    fi

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        sudo systemctl restart cloudflared && ok "cloudflared restarted"
    fi
fi

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
