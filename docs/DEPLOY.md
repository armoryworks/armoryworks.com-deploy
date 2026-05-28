# armoryworks.com — deploy runbook

armoryworks.com is a **single static site**: one nginx container (image built from the `armoryworks.com` source repo), on one box, fronted by host nginx + Cloudflare Tunnel. No API, no database. This is the trivial slice of the shared AWT deploy conventions (see the source repo's `docs/deploy-conventions.md`; `forge-deploy` is the reference).

## 1. Prerequisites

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 git curl jq
sudo usermod -aG docker $USER   # log out/in for it to take effect
docker --version && docker compose version
```

## 2. Clone

```bash
sudo mkdir -p /opt/armoryworks-deploy && sudo chown $USER:$USER /opt/armoryworks-deploy
git clone https://github.com/armoryworks/armoryworks.com-deploy.git /opt/armoryworks-deploy
cd /opt/armoryworks-deploy
```

## 3. Install the CLI + GHCR auth

```bash
./scripts/install-aw-deploy.sh      # installs aw-deploy + aw-preflight, prompts for a read:packages PAT
```

This places `aw-deploy` and `aw-preflight` in `/usr/local/bin`, creates `/etc/armoryworks/` (state + log), and runs `docker login ghcr.io` so the private `armory-works-ui` image can be pulled.

## 4. First-time setup

```bash
./setup-web.sh
```

Writes `.env` from `.env.web.example`, installs the maintenance page to `/var/www/armoryworks-maintenance/`, pulls the image, and brings the container up on `127.0.0.1:${UI_PORT:-4203}`.

## 5. Host nginx + tunnel (one-time host bootstrap)

```bash
sudo cp ops/nginx/armoryworks.com.conf /etc/nginx/sites-available/armoryworks.com.conf
sudo ln -s /etc/nginx/sites-available/armoryworks.com.conf /etc/nginx/sites-enabled/   # if not already linked
sudo nginx -t && sudo systemctl reload nginx
```

The vhost terminates TLS with the Cloudflare Origin Cert, proxies `/` → `127.0.0.1:4203`, and serves the maintenance page (503) on any upstream-down window. Cloudflare Tunnel ingress for `armoryworks.com` lives in `ops/cloudflared/config.yml`.

## 6. Deploy / upgrade

```bash
aw-preflight              # read-only GO/NO-GO check before deploying
aw-deploy --list          # see recent published versions
aw-deploy 0.1.11          # pin + pull + recreate + health-gate (rolls back on failure)
aw-deploy                 # interactive: pick a version
aw-deploy --up            # recreate on the currently pinned tag (e.g. after a compose edit)
aw-deploy --status        # deployed version + container health
aw-deploy --rollback      # re-pin to the previous version
aw-deploy --logs          # deploy history
aw-deploy --self-update   # git pull + reinstall the CLI
```

The health gate curls the **host-published port** (`127.0.0.1:UI_PORT/`), not just the container's internal healthcheck — so a port/upstream misconfig fails the gate and rolls back instead of reporting a false "healthy."

## 7. Co-host port map

This box runs three stacks; each container binds a distinct `127.0.0.1` port and host nginx routes by hostname:

| Port | Stack | Hostname |
|---|---|---|
| 4200 | forge-ui | forge.armoryworks.com |
| 4300 | forge-test | demo/test |
| **4203** | **armory-works-ui** | **armoryworks.com** |
| 5100 / 5101 | tuyere api / web | tuyere.armoryworks.com |

`UI_PORT` (default 4203) and the vhost's `proxy_pass` target must match. Don't move armoryworks onto 4200/4300 (forge) or 5101 (tuyere).
