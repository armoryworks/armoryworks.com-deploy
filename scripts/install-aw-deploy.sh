#!/usr/bin/env bash
# install-aw-deploy.sh — install aw-deploy onto a production host.
#
# Run once per host (api box and/or web box). Idempotent — safe to re-run
# for self-update.
#
# Expects this repo to already be cloned at /opt/armoryworks-deploy (or
# wherever AW_DEPLOY_REPO points). This is a PUBLIC repo, so cloning needs
# no auth:
#
#   sudo mkdir -p /opt && sudo chown $USER:$USER /opt
#   cd /opt
#   git clone https://github.com/armoryworks/armoryworks.com-deploy.git armoryworks-deploy
#   cd armoryworks-deploy
#   ./scripts/install-aw-deploy.sh
#
# What it does:
#   1. Verify prereqs (docker, docker compose, curl, jq)
#   2. Install aw-deploy to /usr/local/bin/aw-deploy
#   3. Create /etc/armoryworks/ with state + log files
#   4. Configure GHCR auth (PAT) for private image pulls:
#        a. Prompt for GitHub username + PAT (or accept GHCR_USER + GHCR_TOKEN env vars)
#        b. Run `docker login ghcr.io` (writes ~/.docker/config.json)
#        c. Save PAT to /etc/armoryworks/ghcr-{user,token} for aw-deploy's
#           own GHCR API calls (list tags, verify manifests)
#
# Options:
#   --skip-auth   Skip the GHCR-auth step (used internally by aw-deploy --self-update
#                 to reinstall the CLI without re-prompting).
#
# PAT scopes required:
#   - Classic PAT: read:packages
#   - Fine-grained PAT: Read on the armory-works-ui package
#
# Non-interactive override:
#   GHCR_USER=<gh-username> GHCR_TOKEN=ghp_xxx ./install-aw-deploy.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_USER="${SUDO_USER:-$USER}"

SKIP_AUTH=false
for arg in "$@"; do
    case "$arg" in
        --skip-auth)   SKIP_AUTH=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m[!!]\033[0m %s\n' "$1"; }
fail() { printf '    \033[31m[XX]\033[0m %s\n' "$1" >&2; exit 1; }

step "Verifying prerequisites"

for cmd in docker curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing: $cmd (sudo apt install -y $cmd)"
done
docker compose version >/dev/null 2>&1 || fail "Missing: docker compose plugin"
ok "All prereqs present"

step "Installing aw-deploy + aw-preflight to /usr/local/bin/"
sudo install -m 0755 "${REPO_ROOT}/scripts/aw-deploy" /usr/local/bin/aw-deploy
ok "/usr/local/bin/aw-deploy"
if [[ -f "${REPO_ROOT}/scripts/aw-preflight" ]]; then
    sudo install -m 0755 "${REPO_ROOT}/scripts/aw-preflight" /usr/local/bin/aw-preflight
    ok "/usr/local/bin/aw-preflight"
fi

step "Creating /etc/armoryworks/"
if [[ ! -d /etc/armoryworks ]]; then
    sudo install -d -m 0750 -o "$DEPLOY_USER" /etc/armoryworks
    ok "Created /etc/armoryworks (owner: $DEPLOY_USER, mode 0750)"
else
    ok "/etc/armoryworks already exists"
fi

step "Creating /etc/armoryworks/deploy-state.json"
if [[ ! -f /etc/armoryworks/deploy-state.json ]]; then
    printf '{}\n' | sudo tee /etc/armoryworks/deploy-state.json >/dev/null
    sudo chown "$DEPLOY_USER":"$DEPLOY_USER" /etc/armoryworks/deploy-state.json
    sudo chmod 0640 /etc/armoryworks/deploy-state.json
    ok "Created (empty state, mode 0640, owner $DEPLOY_USER)"
else
    ok "deploy-state.json already exists"
fi

step "Creating /var/log/aw-deploy.log"
if [[ ! -f /var/log/aw-deploy.log ]]; then
    sudo touch /var/log/aw-deploy.log
    sudo chown "$DEPLOY_USER":"$DEPLOY_USER" /var/log/aw-deploy.log
    sudo chmod 0644 /var/log/aw-deploy.log
    ok "Created (mode 0644, owner $DEPLOY_USER)"
else
    ok "aw-deploy.log already exists"
fi

# No host-role marker: armoryworks.com is a single static service on one box.
# (The old api/web split — and /etc/armoryworks/role — is retired; aw-deploy
# no longer reads it.)

# ─────────────────────────────────────────────────────────────
# GHCR auth
# ─────────────────────────────────────────────────────────────

if $SKIP_AUTH; then
    warn "Skipping GHCR auth step (--skip-auth)"
else
    step "Configuring GHCR auth (private packages)"

    if [[ -r /etc/armoryworks/ghcr-token ]] && [[ -r /etc/armoryworks/ghcr-user ]]; then
        warn "GHCR credentials already present in /etc/armoryworks/."
        warn "To rotate, delete /etc/armoryworks/ghcr-{user,token} and re-run."
    else
        if [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
            ok "Using GHCR_USER + GHCR_TOKEN from environment"
        else
            echo ""
            echo "    A GitHub PAT is required to pull private images from GHCR."
            echo "    Create one at: https://github.com/settings/tokens/new"
            echo "      - Type: Classic"
            echo "      - Scope: read:packages (only)"
            echo "      - Expiration: as long as your org policy allows"
            echo ""
            read -rp "    GitHub username: " GHCR_USER
            [[ -z "$GHCR_USER" ]] && fail "Username is required"
            read -srp "    GitHub PAT (input hidden): " GHCR_TOKEN
            echo ""
            [[ -z "$GHCR_TOKEN" ]] && fail "PAT is required"
        fi

        if echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1; then
            ok "docker login ghcr.io succeeded"
        else
            fail "docker login ghcr.io failed — verify the PAT has read:packages scope"
        fi

        printf '%s' "$GHCR_USER"  | sudo tee /etc/armoryworks/ghcr-user  >/dev/null
        printf '%s' "$GHCR_TOKEN" | sudo tee /etc/armoryworks/ghcr-token >/dev/null
        sudo chown "$DEPLOY_USER":"$DEPLOY_USER" /etc/armoryworks/ghcr-user /etc/armoryworks/ghcr-token
        sudo chmod 0640 /etc/armoryworks/ghcr-user
        sudo chmod 0600 /etc/armoryworks/ghcr-token
        ok "Saved /etc/armoryworks/ghcr-user (0640) and ghcr-token (0600)"
    fi
fi

step "Verifying install"
aw-deploy --version
ok "aw-deploy is ready"

printf '\n'
echo "Next steps:"
echo "  - First-time setup:   cd ${REPO_ROOT} && ./setup-web.sh"
echo "  - Preflight check:    aw-preflight"
echo "  - List available:     aw-deploy --list"
echo "  - Deploy a tag:       aw-deploy <X.Y.Z|main-sha>"
echo "  - Interactive:        aw-deploy"
echo "  - Status:             aw-deploy --status"
echo "  - Rollback:           aw-deploy --rollback"
echo ""
