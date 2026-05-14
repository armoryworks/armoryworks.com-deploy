# armoryworks.com-deploy

Deployment configuration and CLI for `armoryworks.com` production hosts.

This repo contains **only the deploy surface** — compose files, the `aw-deploy`
CLI, env templates, and the host nginx vhost. The application source lives in
the private [`armoryworks.com`](https://github.com/armoryworks/armoryworks.com)
repo and is delivered to production exclusively as pre-built Docker images via
[GitHub Container Registry](https://github.com/orgs/armoryworks/packages).

This repo is **public**. Nothing in it is sensitive:

- The compose files describe service shapes; secrets are filled into a
  box-local `.env` that is **never committed**.
- The `.env.*.example` files are templates with empty values.
- The nginx vhost references the internal LAN IP `192.168.1.198`, which is an
  RFC 1918 private address — useless to anyone outside the LAN.

The split mirrors the
[forge / forge-deploy](https://github.com/danielhokanson) pattern: source
repos stay private when warranted, deploy repos stay public because they
contain no secrets and benefit from anonymous cloning on production hosts.

---

## Topology

```
                    Cloudflare DNS
                          │
                          ▼
                Cloudflare Tunnel (outbound from web box)
                          │
                          ▼
        ┌───────────────────────────────────┐
        │  armoryworks-web (this repo + UI) │
        │  - cloudflared                    │
        │  - host nginx (TLS via Origin)    │
        │  - armory-works-ui container      │
        │    (from ghcr.io/armoryworks/...) │
        └────────┬──────────────────────────┘
                 │ /api/* over LAN (192.168.1.x)
                 ▼
        ┌───────────────────────────────────┐
        │  armoryworks-api                  │
        │  - armory-works-server container  │
        │    (from ghcr.io/armoryworks/...) │
        │  - armory-works-db (Postgres)     │
        │    (Docker network only)          │
        └───────────────────────────────────┘
```

- **Web box** runs the Angular UI in a small nginx container, plus the host
  nginx that terminates TLS with a Cloudflare Origin Cert and proxies
  `/api/*` across the LAN to the API box.
- **API box** runs the .NET API and Postgres. The API is reachable only from
  the web box (UFW restricts `8203/tcp` to `192.168.1.0/24`). Postgres is
  never published to the host.
- All public traffic enters via **Cloudflare Tunnel**; no port `:80` or `:443`
  is open on either box.

---

## First-time install

On each production host (web box and api box):

```bash
# 1. Clone this repo (public — no auth needed)
sudo mkdir -p /opt && sudo chown $USER:$USER /opt
cd /opt
git clone https://github.com/armoryworks/armoryworks.com-deploy.git armoryworks-deploy

# 2. Install the aw-deploy CLI + state directories + GHCR auth
cd /opt/armoryworks-deploy
./scripts/install-aw-deploy.sh
# Prompts for GitHub username + PAT.
# PAT scope: read:packages (and 'repo' if you ever want write access; otherwise just read:packages).

# 3. Bring up the stack for the first time (role-specific)
./setup-api.sh    # on armoryworks-api
./setup-web.sh    # on armoryworks-web

# 4. Pin to an immutable tag (no more 'latest')
aw-deploy --list
aw-deploy main-<sha>
```

---

## Ongoing operations

```bash
aw-deploy --list           # see available tags from GHCR
aw-deploy main-<sha>       # deploy a specific immutable tag (all local services)
aw-deploy main-<sha> --service api    # narrow to one
aw-deploy --status         # current + prior + container health
aw-deploy --rollback       # revert to the previously deployed tag
aw-deploy --logs           # tail /var/log/aw-deploy.log
aw-deploy --self-update    # git pull this repo, reinstall CLI
```

---

## Service inventory

| Service | Image | Host | Compose file |
|---|---|---|---|
| `armory-works-server` | `ghcr.io/armoryworks/armory-works-server` | api box | `docker-compose.api.yml` |
| `armory-works-db` (Postgres) | `postgres:16-alpine` | api box | `docker-compose.api.yml` |
| `armory-works-ui` | `ghcr.io/armoryworks/armory-works-ui` | web box | `docker-compose.web.yml` |

`aw-deploy` auto-detects which services this host manages by which compose
file is present.

---

## State files

| Path | Mode | Contents |
|---|---|---|
| `/opt/armoryworks-deploy/` | 0755 | This repo, owned by deploy user |
| `/opt/armoryworks-deploy/.env` | 0640 | Operator's filled-in config (NEVER committed) |
| `/etc/armoryworks/deploy-state.json` | 0640 | aw-deploy's current/prior tag per service |
| `/etc/armoryworks/ghcr-user` | 0640 | GitHub username for GHCR auth |
| `/etc/armoryworks/ghcr-token` | 0600 | PAT for GHCR (`read:packages`) |
| `/var/log/aw-deploy.log` | 0644 | Deploy history |

---

## Source repo

The application code lives at
[`armoryworks/armoryworks.com`](https://github.com/armoryworks/armoryworks.com)
(private). That repo's GitHub Actions workflows build and push the Docker
images that this deploy repo consumes.

## License

MIT — see [LICENSE](LICENSE).
