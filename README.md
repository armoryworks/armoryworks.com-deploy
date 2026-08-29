# armoryworks.com-deploy

Deployment configuration and operator CLI for the Armory Works production hosts.

This repository holds everything needed to run the **armoryworks.com** marketing
site (<https://armoryworks.com>) on the `armoryworks-web` box: the production
compose file, the host nginx and Cloudflare Tunnel configuration, a first-time
setup script, and `aw-deploy` — the deploy CLI that pins an immutable image tag,
recreates the container, health-gates the result, and rolls back on failure.

No application source lives here. The site itself is an Eleventy build packaged
as an nginx container and published to GHCR by its own (private) source repo;
this repo only decides which tag runs and how it is fronted.

## What gets deployed

`docker-compose.web.yml` (compose project `armory-works-web`) defines two
services:

| Service | Image | Binds |
|---|---|---|
| `armory-works-ui` | `ghcr.io/armoryworks/armory-works-ui:${UI_IMAGE_TAG}` | `127.0.0.1:${UI_PORT:-4203}` → container `:80` |
| `tuyere-writing-receiver` | `ghcr.io/armoryworks/tuyere-writing-receiver:${WRITING_RECEIVER_IMAGE_TAG:-edge}` | `${WRITING_RECEIVER_BIND}:${WRITING_RECEIVER_PORT:-5103}` → container `:8080` |

`armory-works-ui` serves the whole site as static files. The one dynamic input
is `/writing`: a host directory (`WRITING_CONTENT_DIR`, default
`/var/lib/armoryworks/writing`) bind-mounted **read-only** into the UI container
at `/usr/share/nginx/html/writing`. `tuyere-writing-receiver` accepts gzipped
tar bundles from `tuyere-api` on the API box (bearer auth) and extracts them
into that directory. Serving stays pure-static — nginx reads files off disk and
never calls Tuyere at request time.

Only `armory-works-ui` is under release-tag discipline. The receiver pins a
rolling `edge` tag and is deliberately absent from `deploy.manifest.json`; it is
managed with `aw-deploy compose`.

## Topology

```
Cloudflare edge
      │  (outbound-initiated tunnel, cloudflared)
      ▼
host nginx on armoryworks-web  ── TLS: Cloudflare Origin Cert
      │  routes by Host header
      ├─ armoryworks.com          → 127.0.0.1:4203   (armory-works-ui, this repo)
      ├─ forge.armoryworks.com    → armoryworks-api over LAN
      ├─ forge-demo / forge-test  → armoryworks-api over LAN
      └─ logs.armoryworks.com     → armoryworks-api over LAN
```

The web box is co-hosted. Each container binds a distinct loopback port and
never listens publicly; host nginx is the only front door. Port assignments are
recorded in `docs/DEPLOY.md` §7 — `UI_PORT` (4203) must match the vhost's
`proxy_pass` target, and must not collide with forge (4200/4300) or tuyere
(5100/5101).

`ops/cloudflared/config.yml` is the tunnel ingress for all of the above; it is
installed to `/etc/cloudflared/config.yml` separately from the container-side
setup.

## Prerequisites

- Ubuntu host with `docker`, the `docker compose` v2 plugin, `git`, `curl`, `jq`
- A GitHub PAT with `read:packages` (classic) or Read on the `armory-works-ui`
  package — the images are private
- Cloudflare Origin Certificate installed at
  `/etc/letsencrypt/live/armoryworks.com.cloudflare/{fullchain,privkey}.pem`
- `inotify-tools`, if the `/writing` redirect-map reload service is used

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 git curl jq
sudo usermod -aG docker "$USER"   # log out/in to take effect
```

## First-time host setup

```bash
sudo mkdir -p /opt/armoryworks-deploy && sudo chown "$USER:$USER" /opt/armoryworks-deploy
git clone https://github.com/armoryworks/armoryworks.com-deploy.git /opt/armoryworks-deploy
cd /opt/armoryworks-deploy

./scripts/install-aw-deploy.sh   # installs the CLI, creates /etc/armoryworks, docker login ghcr.io
./setup-web.sh                   # .env, image pull, nginx vhosts, /writing dir, containers up
```

`install-aw-deploy.sh` installs `aw-deploy` and `aw-preflight` into
`/usr/local/bin`, creates `/etc/armoryworks/` with `deploy-state.json` and the
GHCR credential files, and creates `/var/log/aw-deploy.log`. It prompts for the
PAT interactively, or accepts `GHCR_USER` / `GHCR_TOKEN` from the environment.
Pass `--skip-auth` to reinstall the CLI without touching credentials.

`setup-web.sh` is idempotent and safe to re-run. It writes `.env` from
`.env.web.example`, sets the receiver bind address and bearer token (generating
one if blank), pulls the UI image, installs the maintenance page, creates and
seeds the `/writing` content directory, installs and validates the host nginx
vhosts, installs the `armoryworks-writing-reload` systemd service, applies the
UFW rule for the receiver port, wires cloudflared ingress for
`tuyere.armoryworks.com`, and brings the containers up.

Configuration lives in `.env` next to the compose file — copy
`.env.web.example` and fill it in. `.env` is gitignored and must never be
committed. `UI_IMAGE_TAG` is rewritten by `aw-deploy` on every deploy; hand
edits to it are lost.

## Operating

```bash
aw-preflight              # read-only GO/NO-GO check; run this first
aw-preflight --quiet      # problems and verdict only

aw-deploy --list          # recent release tags in GHCR
aw-deploy --list --builds # recent build tags (main-<sha> / sha-<sha>) instead
aw-deploy 0.1.11          # pin + pull + recreate + health gate, rollback on failure
aw-deploy                 # interactive: pick from recent versions
aw-deploy --up            # recreate on the currently pinned tag (e.g. after a compose edit)
aw-deploy --status        # deployed version + container health
aw-deploy --rollback      # re-pin to the previously deployed version
aw-deploy --logs          # deploy history
aw-deploy --self-update   # git pull the tool checkout + reinstall the CLI
aw-deploy --version
aw-deploy --help
```

Use `aw-deploy compose <args>` rather than bare `docker compose` — it resolves
the right compose file and env file for the component:

```bash
aw-deploy compose ps
aw-deploy compose logs -f armory-works-ui
aw-deploy compose pull tuyere-writing-receiver
```

Tags must be immutable: `X.Y.Z` / `vX.Y.Z`, or `main-<sha>` / `sha-<sha>` with a
7–40 character hex sha. `latest` is always refused, so there is always a
previous pin to roll back to.

The health gate curls each service's **host-published** port
(`127.0.0.1:UI_PORT/`), not just the container's internal healthcheck — a
port or upstream misconfiguration fails the gate and rolls back rather than
reporting a false healthy.

State is kept at `/etc/armoryworks/deploy-state.json`, history at
`/var/log/aw-deploy.log`.

### Multi-stack use

Since 0.3.0 `aw-deploy` is stack-agnostic: all product-specific detail lives in
the `deploy.manifest.json` at the root of each `*-deploy` repo. Point the CLI at
another stack with `-r/--repo`:

```bash
aw-deploy -r /opt/nommeal-deploy nom v0.1.2
aw-deploy -r /opt/nommeal-deploy compose nom logs -f nom-api
```

The repo defaults to `$AW_DEPLOY_REPO`, then `/opt/armoryworks-deploy`. This
repo's manifest declares a single component (`site`), so the bare
`aw-deploy <tag>` form resolves without naming it. `--self-update` always
targets the tool's own checkout (`AW_TOOL_HOME`), not `--repo`.

Other environment overrides: `AW_STATE_DIR`, `AW_LOG_FILE`, `NO_COLOR`.

## Layout

```
deploy.manifest.json      Stack manifest read by aw-deploy (components, images, health probes)
docker-compose.web.yml    Production compose: armory-works-ui + tuyere-writing-receiver
.env.web.example          Template for the operator-provided .env
setup-web.sh              Idempotent first-time (and re-run) host setup
scripts/
  install-aw-deploy.sh    Installs the CLI, /etc/armoryworks state, GHCR auth
  aw-deploy               Deploy CLI
  aw-preflight            Read-only deploy doctor
ops/
  nginx/                  Host vhosts for armoryworks.com and the co-hosted forge/logs surfaces
  cloudflared/config.yml  Tunnel ingress for every hostname on this box
  maintenance/            Branded 503 page served when the upstream is down
  writing-reload.sh       inotify watcher: nginx -t && nginx -s reload on /writing map changes
docs/
  DEPLOY.md               Full runbook
  TROUBLESHOOTING.md      Symptom → cause → fix, from real incidents
CHANGELOG.md              Notable changes; versions track the aw-deploy CLI
```

`.gitattributes` pins `eol=lf` repo-wide: a CRLF line ending on a shell script
breaks the shebang on Linux, and `aw-preflight` checks for exactly that.

## License

MIT. See [LICENSE](LICENSE).
