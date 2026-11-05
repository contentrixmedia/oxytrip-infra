# oxytrip-infra

Compose, edge Caddy, env templates, and runbooks for the **oxytrip-frontend** public
site and the **Oxytrip unified panel** (CMS + support bot). Neither app owns this
repo — it sits beside both.

## Layout

```
compose/docker-compose.base.yml     # services, networks, healthchecks — no ports
compose/docker-compose.local.yml    # build sibling repos, mongo, tls internal
compose/docker-compose.prod.yml     # image tags, host-based TLS, resource limits
caddy/Caddyfile                     # production: SITE_DOMAIN + PANEL_DOMAIN
caddy/Caddyfile.local               # localhost path split (/ → site, /cms /bot → panel)
env/frontend.env.example
env/panel.env.example
scripts/stack.sh
scripts/healthcheck.sh
scripts/backup-bot-db.sh            # nightly support-bot database backup (+ restore)
```

Sibling repos (not submodules):

- `../oxytrip-frontend` — Next.js site, **port 3000**, `CMD node server.js`
  (local build uses `docker/frontend.Dockerfile` here — pins `@next/swc-linux-x64-gnu`)
- `../Oxytrip-cms/oxytrip-cms` — unified panel, **port 8080** (Caddy), CMS :3000 + bot :4000 internal

## Routing

| Mode | Site | Panel |
|------|------|-------|
| **Local** (`Caddyfile.local`) | `https://localhost/` → frontend:3000 | `/cms/*`, `/bot/*` → panel:8080 |
| **Prod** (`Caddyfile`) | `{$SITE_DOMAIN}` → frontend:3000 | `{$PANEL_DOMAIN}` → panel:8080 (path-based /cms /bot inside panel) |

Panel routing is **path-based on its own hostname** (see `Oxytrip-cms/oxytrip-cms/Caddyfile`).
Edge preserves `flush_interval -1` on `/bot/*` for SSE.

Only **edge** publishes 80/443. App containers are on the internal `app` network with
`expose` only — `curl http://localhost:3000` from the host must fail.

## Local run

```bash
cp env/frontend.env.example env/frontend.env
cp env/panel.env.example env/panel.env
# fill values — or use the committed local dev templates if present

./scripts/stack.sh up local
./scripts/healthcheck.sh https://localhost
```

Requires Docker, Node (for healthcheck script), and sibling repos checked out alongside
this directory.

## Images (GHCR)

| Service | Image | Dockerfile |
|---------|--------|------------|
| frontend | `ghcr.io/contentrixmedia/oxytrip-site` | `oxytrip-frontend/Dockerfile.server` |
| panel | `ghcr.io/contentrixmedia/oxytrip-cms` | `Oxytrip-cms/oxytrip-cms/Dockerfile` |

A push to `main` publishes the git SHA and moves the **`staging`** tag. A git tag publishes the SHA only. Nothing auto-tags `latest` or `prod`.

**Production is pinned to a git SHA, never to a moving tag** (`staging`, `latest`, `prod`). Promotion is: copy the SHA you verified, set `FRONTEND_TAG` / `PANEL_TAG` in the server's `env/stack.env`, then `pull` and `up`.

```bash
cp env/stack.env.example env/stack.env
# staging: FRONTEND_TAG=staging  PANEL_TAG=staging
# prod:    FRONTEND_TAG=<40-char sha>  PANEL_TAG=<40-char sha>

docker login ghcr.io
./scripts/stack.sh pull staging
./scripts/stack.sh up staging
./scripts/healthcheck.sh https://localhost
```

`compose/staging.yml` and `compose/prod.yml` mount a named volume at the frontend's `/app/.next/cache` so the ISR and image cache survive restarts. The frontend runs as the image's `nextjs` user (1001:1001); the one-shot `frontend-cache-perms` service chowns that volume as root first and exits (it shows as `Exited (0)` in `ps` - that is expected).

## Production run

```bash
cp env/frontend.env.example env/frontend.env
cp env/panel.env.example env/panel.env
cp env/stack.env.example env/stack.env
# edit stack.env: SHA pins, SITE_DOMAIN, PANEL_DOMAIN, ACME_EMAIL

docker login ghcr.io
./scripts/stack.sh pull prod
./scripts/stack.sh up prod
./scripts/healthcheck.sh https://www.example.com
```

## Scripts

| Script | Purpose |
|--------|---------|
| `./scripts/stack.sh up local` | Build + start local stack |
| `./scripts/stack.sh pull staging` | Pull GHCR images named in `env/stack.env` |
| `./scripts/stack.sh up staging` | Start staging (no local build) |
| `./scripts/stack.sh up prod` | Start production, SHA-pinned |
| `./scripts/stack.sh down local` | Stop |
| `./scripts/stack.sh logs local` | Follow logs |
| `./scripts/stack.sh ps local` | Container status |
| `./scripts/healthcheck.sh <base-url>` | Monitoring probe through Caddy |
| `sudo ./scripts/backup-bot-db.sh` | Back up the bot's SQLite (chats) to `backups/bot/`, 14 kept, optional encrypted off-site copy |
| `sudo ./scripts/backup-bot-db.sh install-cron` | Run that nightly (23:40 UTC); log `/var/log/oxytrip-bot-backup.log` |
| `sudo ./scripts/backup-bot-db.sh restore <file>` | Put a backup back into the panel's volume (stops/starts the panel) |

## Ports (from Dockerfiles)

| Service | Container listen | Published to host |
|---------|------------------|-------------------|
| frontend | 3000 (`Dockerfile.local` EXPOSE 3000) | **no** |
| panel | 8080 (unified `Dockerfile` EXPOSE 8080, `$PORT`) | **no** |
| edge | 80, 443 | **yes** |

Panel internal (not on Docker network): CMS `127.0.0.1:3000`, bot `127.0.0.1:4000`.
