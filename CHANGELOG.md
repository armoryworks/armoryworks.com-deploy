# Changelog

Notable changes to `armoryworks.com-deploy`. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions track the `aw-deploy` CLI.

## [Unreleased]

### Added
- Dynamic `/writing` content area: a host dir (`WRITING_CONTENT_DIR`, default `/var/lib/armoryworks/writing`) bind-mounted **read-only** into the UI container at `/usr/share/nginx/html/writing`, for the co-hosted Tuyere writing CMS to render posts + index + `feed.xml` into. Serving stays pure-static (nginx reads files; never calls Tuyere). `setup-web.sh` creates + seeds the dir with a placeholder index (the mount shadows the image's baked `/writing`). See `docs/DEPLOY.md` §6b.
- Writing CMS slug-move **301 redirects**: `ops/nginx/armoryworks.com.conf` gains a `map $uri $writing_redirect` (reads `_redirects.map`, maintained by Tuyere on publish) + an apex `return 301`; `setup-web.sh` seeds an empty `_redirects.map`; `ops/writing-reload.sh` (inotify) runs `nginx -t && nginx -s reload` when Tuyere rewrites the map. See `docs/DEPLOY.md` §6b.

### Changed
- `docker-compose.web.yml`, `.env.web.example`, `setup-web.sh` — dropped stale Angular-/api-box header comments now that this box is static-site only.

## [0.2.0] — 2026-05-28

Static collapse + convergence to the shared AWT deploy conventions (`forge-deploy` is the reference; see the source repo's `docs/deploy-conventions.md`). armoryworks.com is now a single static service, so the api/web split is gone.

### Added
- `scripts/aw-preflight` — read-only deploy doctor (repo/remote, ownership, CRLF, docker, `.env` + pinned tag, GHCR creds, state file, maintenance page). GO / NO-GO with per-check fixes.
- `aw-deploy --up` — recreate the container on the currently pinned tag (e.g. after a compose edit), health-gated.
- `aw-deploy compose <args>` — scope-aware `docker compose` passthrough.
- `docs/DEPLOY.md`, `docs/TROUBLESHOOTING.md`, this changelog.
- `.gitattributes` (`* text=auto eol=lf`) so a Windows edit can't ship a CRLF interpreter line.
- Maintenance-page fallback: host nginx `error_page 502 503 504 =503` → branded local 503; `setup-web.sh` installs the page.

### Changed
- `aw-deploy` rewritten for a single static service (0.1.1 → 0.2.0): dropped the `api` descriptor, role detection, dual-compose, and the EF-migrations block. Health gate now checks the **host-published port** (`127.0.0.1:UI_PORT/`), not the container's internal healthcheck. Configurable, validated health timeout (default 120s).
- `docker-compose.web.yml` publishes `127.0.0.1:UI_PORT:80` (was `:8080`, an Angular-era mismatch that 502'd the live site).
- `armoryworks.com.conf` — removed the dead `/api` + OIDC proxy blocks; added `https://tuyere.armoryworks.com` to the CSP `connect-src` so the contact form can post.
- `install-aw-deploy.sh` installs `aw-preflight`; dropped the obsolete host-role marker.

### Removed
- `docker-compose.api.yml`, `setup-api.sh`, `.env.api.example` — the .NET API is gone (its admin surface moved to Tuyere).
- All references to the product's former name (in the deleted `.api` files + the cloudflared comment). Forge is the only name now.

## [0.1.1] — 2026-05-27

### Fixed
- Health gate now curls the published port instead of trusting the container's internal healthcheck — catches the 8080-vs-80 mismatch that reported "healthy" over a 502'ing site.
- `docker-compose.web.yml` container port corrected 8080 → 80.

## [0.1.0]

### Added
- Initial `aw-deploy` CLI ported from `forge-deploy`: GHCR pull, immutable-tag pin, `--list`/`--status`/`--rollback`/`--logs`/`--self-update`, healthcheck-gated rollback, state + log.
