# armoryworks.com — troubleshooting

Symptom → cause → fix, from real incidents on this deploy.

## Cloudflare 502 page on the live site

**Cause:** host nginx can't reach the UI container — it's down, or the published port maps to a container port nothing listens on.

- The static image runs nginx on **container port 80**. `docker-compose.web.yml` must publish `127.0.0.1:${UI_PORT}:80` (not `:8080` — the old Angular image listened on 8080; that mismatch 502'd the site while the container's own healthcheck still passed).
- Check: `curl -I http://127.0.0.1:4203/` on the box. Connection-refused = nothing on that port → fix the compose mapping and `aw-deploy --up`.
- With the vhost's `error_page` fallback installed, an upstream-down window shows the **branded maintenance 503**, not Cloudflare's 502. If you see Cloudflare's own page, the maintenance file isn't installed: `sudo install -D -m 0644 ops/maintenance/maintenance.html /var/www/armoryworks-maintenance/maintenance.html`.

## `aw-deploy` says "healthy" but the site is still down

**Cause (pre-0.2.0):** the gate checked the container's internal healthcheck (port 80 inside), not the published port. **Fixed:** 0.2.0's gate curls `127.0.0.1:UI_PORT/`. Run `aw-deploy --version` — if it's < 0.2.0, `aw-deploy --self-update`.

## `aw-deploy` refuses to deploy

- **"Refusing to deploy 'latest'"** — pass an immutable tag: `aw-deploy --list`, then `aw-deploy <X.Y.Z>` or `aw-deploy main-<sha>`.
- **"Invalid tag format"** — tags must be `X.Y.Z` or `main-<7..40 hex>`.

## GHCR pull fails with `unauthorized`

**Cause:** the `armory-works-ui` package is private and the box isn't authenticated.

```bash
./scripts/install-aw-deploy.sh        # re-runs docker login ghcr.io + stores the PAT
```

PAT needs `read:packages` (classic) or Read on the `armory-works-ui` package (fine-grained).

## `bad interpreter: /usr/bin/env bash^M`

**Cause:** a script got CRLF line endings (edited on Windows without `.gitattributes`). The repo ships `.gitattributes` (`* text=auto eol=lf`); if a file already has CRLF: `sed -i 's/\r$//' <file>`. `aw-preflight` flags this.

## `aw-deploy --self-update` refuses

**"Local changes to tracked files present"** — something was hand-edited in `/opt/armoryworks-deploy`. Stash/revert, or pull manually: `cd /opt/armoryworks-deploy && git pull --ff-only && sudo ./scripts/install-aw-deploy.sh --skip-auth`.

## Contact form fails in the browser (CORS / blocked request)

**Cause:** the form posts cross-origin to `https://tuyere.armoryworks.com/api/public/contact`. Two requirements:
1. Host nginx CSP `connect-src` must include `https://tuyere.armoryworks.com` (it does, in `armoryworks.com.conf`).
2. Tuyere's endpoint must send `Access-Control-Allow-Origin: https://armoryworks.com`. That's a **Tuyere-side** config — not fixable here.

## Preflight first

Before chasing anything, run `aw-preflight` — it checks the repo/remote, perms, CRLF, docker, `.env` + pinned tag, GHCR creds, state file, and the maintenance page, and prints the exact fix for each failure.
