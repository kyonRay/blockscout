# Potos Blockscout — Operations Guide

Audience: deploy / ops engineers running the potos explorer.
Scope: everything from building the bundle to running it in production.

## Contents

1. [Prerequisites](#prerequisites)
2. [Building the bundle](#building-the-bundle-packagesh)
3. [Known network issues & workarounds](#known-network-issues--workarounds)
4. [Single-host deployment](#single-host-deployment)
5. [Multi-host deployment](#multi-host-deployment)
6. [Active-standby / HA](#active-standby--ha)
7. [Day-2 operations](#day-2-operations)
8. [Troubleshooting](#troubleshooting)
9. [Upgrading to a newer upstream tag](#upgrading-to-a-newer-upstream-tag)
10. [Rollback](#rollback)

---

## Prerequisites

**On the build host:**

| Tool | Version | Notes |
|---|---|---|
| Docker Engine | 24.x+ | with compose v2 plugin |
| Docker Compose | v2.20+ | provided by Docker Desktop / `docker-compose-plugin` package |
| `envsubst` | any | `gettext` package on Linux / macOS |
| `bash` | 4+ | for `set -o pipefail` |
| `git` | 2.20+ | needs `worktree` subcommand |
| Disk | ~8 GB free | image cache + build artifacts + tarball |
| RAM | ~6 GB free during build | Elixir compile is memory-hungry |

**On each deploy host:**

| Tool | Version |
|---|---|
| Docker Engine | 24.x+ |
| Docker Compose | v2.20+ |
| Disk | ~20 GB for a small chain; scale with retained history |

**Access:**

- Push/pull access to `origin` for the `potos/v*` branches
- Outbound HTTPS to `docker.io` and `ghcr.io` (for upstream service images)
- During build: outbound HTTPS to `github.com` releases (for precompiled native deps)

---

## Building the bundle (`package.sh`)

The bundle (`package/output.tar.gz`) is a self-contained deployment artifact. Build it from the `potos/v10.2.6` branch:

```bash
git checkout potos/v10.2.6

cd package
cp deploy.config.example deploy.config
$EDITOR deploy.config       # fill in passwords, RPC URLs, chain ID — see annotations in the file

./package.sh
```

Expected completion output:

```
done: ./output.tar.gz
-rw-r--r--  1 user  staff   ~2.1G Apr 20 15:00 ./output.tar.gz
```

### What `package.sh` does

1. Verifies `deploy.config` exists and `docker`/`envsubst` are on `PATH`.
2. Sources `deploy.config` into the environment.
3. `docker compose -f ../docker-compose/potos/potos.yml build backend` — builds the custom Blockscout image, tagging it `${IMAGE_NAME}:${RELEASE_VERSION}`.
4. `docker save` — dumps the image to `output/${IMAGE_NAME}.tar`.
5. Copies tier compose files to `output/`, rewriting `../services/` → `./services/` so they work in the flat bundle layout.
6. Copies upstream `services/`, `envs/`, `proxy/` trees.
7. Renders `.env` / `start.sh` / `stop.sh` from templates via `envsubst`.
8. `tar -czf output.tar.gz -C output .` produces the final bundle.

On any failure, the `ERR`/`INT` trap wipes the partial `output/` directory — no zombie state.

### Capturing real exit code when piping

`set -o pipefail` is set inside `package.sh`. If you pipe the output externally (e.g. `./package.sh | tee log`), `bash` by default returns only `tee`'s exit code. To capture the real result:

```bash
./package.sh 2>&1 | tee build.log
exit ${PIPESTATUS[0]}
```

or in an interactive shell:

```bash
set -o pipefail
./package.sh 2>&1 | tee build.log
```

---

## Known network issues & workarounds

The Elixir build pulls base images and precompiled native dependencies from third-party registries. In restricted network environments (CN networks, corporate proxies, CI without credentials) these can fail intermittently. Below are the failure modes we have seen and their workarounds.

### Issue 1: `auth.docker.io` TCP reset during buildx metadata fetch

**Symptom** (`package.sh` output):

```
#3 [backend internal] load metadata for docker.io/hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.22.2
#3 ERROR: failed to authorize: failed to fetch anonymous token:
  Get "https://auth.docker.io/token?...": read tcp ...: read: connection reset by peer
```

**Root cause**: Docker BuildKit fetches image metadata through a separate auth path from the classic `docker pull`. In some networks the auth endpoint is routed to an edge node that resets the connection.

**Workaround**: pre-pull the base image using the classic daemon path, which uses the configured registry mirror / auth, then retry `package.sh`. BuildKit will then use the locally cached image metadata.

```bash
docker pull hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.22.2
docker pull hexpm/erlang:27.3.4.6-alpine-3.22.2   # if used by any downstream layer
cd package && ./package.sh
```

**Permanent fix** (for a build machine used often): configure a Docker registry mirror in `/etc/docker/daemon.json`:

```json
{
  "registry-mirrors": ["https://<your-mirror-host>"]
}
```

Restart the docker daemon after editing.

### Issue 2: `evision` precompiled artifact download returns HTML instead of tarball

**Symptom**:

```
#17 [backend builder-deps 12/15] RUN ... mix do deps.get + ... deps.compile --skip-umbrella-children
...
     /app/deps/evision/mix.exs:501: Mix.Tasks.Compile.EvisionPrecompiled.download!/1
** (Mix) mix deps.partition #Port<0.405> closed unexpectedly
failed to solve: process "..." did not complete successfully: exit code: 1
```

Look for the actual response body in the log — if it begins with `<!DOCTYPE html>` or GitHub assets CSS links, the request reached GitHub but received an error page (404 / rate-limit / regional block) instead of the expected `.tar.gz`.

**Root cause**: `evision` (OpenCV bindings used by `nft_media_handler`) downloads precompiled native libraries from GitHub releases during `mix deps.compile`. In restricted networks, GitHub release downloads may be rate-limited or blocked, returning an HTML error page that `evision` can't parse.

**Workarounds (pick one)**:

1. **Build from a different host** with clean access to `github.com` releases (e.g., a cloud VM in a permissive region). Transfer the resulting `output.tar.gz` to target deploy hosts.
2. **Use an HTTPS proxy** for the build:
   ```bash
   HTTP_PROXY=http://your-proxy:port \
   HTTPS_PROXY=http://your-proxy:port \
   ./package.sh
   ```
   Compose/BuildKit will pass these through as build args.
3. **Pre-cache the evision artifact** inside the base image via a custom Dockerfile overlay (advanced, requires knowing the artifact URL for your platform). Out of scope for this doc.

**Diagnostic**: manually fetch the failing URL to see what GitHub returns:

```bash
curl -sSL -o /tmp/evision.tar.gz \
  "https://github.com/cocoa-xu/evision/releases/download/<version>/<artifact>.tar.gz"
file /tmp/evision.tar.gz
# Expected: "gzip compressed data". If "HTML document", your network can't reach the artifact.
```

### Issue 3: `ghcr.io` pulls fail at deploy time

**Symptom** during `./start.sh all`:

```
Error response from daemon: Head "https://ghcr.io/v2/blockscout/frontend/manifests/latest": ...
```

**Root cause**: most non-backend services (`frontend`, `stats`, `visualizer`, `sig-provider`, `smart-contract-verifier`, `user-ops-indexer`, `redis`, `postgres`) pull from `ghcr.io` at `docker compose up` time. Restricted networks may block `ghcr.io`.

**Workaround on the build host** (pre-cache then repackage with image tars):

```bash
# 1. Pull every upstream image
for img in \
  ghcr.io/blockscout/frontend:latest \
  ghcr.io/blockscout/stats:latest \
  ghcr.io/blockscout/visualizer:latest \
  ghcr.io/blockscout/sig-provider:latest \
  ghcr.io/blockscout/smart-contract-verifier:latest \
  ghcr.io/blockscout/user-ops-indexer:latest \
  postgres:17 \
  redis:alpine \
  nginx:latest; do
    docker pull "$img"
done

# 2. Save them into the bundle manually
docker save -o package/output/upstream-images.tar \
  ghcr.io/blockscout/frontend:latest \
  ghcr.io/blockscout/stats:latest \
  ghcr.io/blockscout/visualizer:latest \
  ghcr.io/blockscout/sig-provider:latest \
  ghcr.io/blockscout/smart-contract-verifier:latest \
  ghcr.io/blockscout/user-ops-indexer:latest \
  postgres:17 redis:alpine nginx

# 3. Re-tar
tar -czf package/output.tar.gz -C package/output .
```

On the deploy host, load both image tars before `./start.sh`:

```bash
docker load --input ${IMAGE_NAME}.tar
docker load --input upstream-images.tar
./start.sh all
```

> Future work: automate Issue 3 workaround inside `package.sh` behind a `--offline` flag.

---

## Single-host deployment

Fastest path for dev / small production. Single machine runs everything.

1. Copy `output.tar.gz` to the target host.
2. Unpack and start:

   ```bash
   mkdir -p /opt/blockscout-potos && cd /opt/blockscout-potos
   tar -xzf /path/to/output.tar.gz
   ./start.sh all
   ```

3. Wait ~60–90s for DB init and backend migrations.
4. Verify:

   ```bash
   curl -sf http://localhost/api/v2/stats | jq .
   ```

   Expected: JSON with `total_blocks` (may be 0 initially).

5. Access UI at `http://<host-ip>/` (port 80 via `proxy`).

Logs:

```bash
docker compose -f potos.yml logs -f backend
docker compose -f potos.yml logs -f stats
```

Stop:

```bash
./stop.sh all
```

---

## Multi-host deployment

For medium-scale deployments. Each host runs a subset of tiers; cross-host connectivity is wired via `EXTERNAL_*` env variables.

### Example: 3-host layout

| Host | Tier | Compose file |
|---|---|---|
| `db.potos.internal` | persistence | `potos-db.yml` |
| `app.potos.internal` | backend + microservices | `potos-backend.yml`, `potos-microservices.yml` |
| `web.potos.internal` | frontend | `potos-frontend.yml` |

### Host 1: DB tier (`db.potos.internal`)

```bash
# Extract bundle; ensure .env has POSTGRES_*_PASSWORD set and nothing else matters here
./start.sh db
```

This publishes:
- postgres `blockscout` on `host:7432`
- postgres `stats` on `host:7433`
- redis on `host:6379`

Lock down with firewall: expose only to the app host's IP.

### Host 2: Backend + microservices (`app.potos.internal`)

Edit `.env` to point at the DB host:

```
EXTERNAL_DATABASE_URL=postgresql://blockscout:<POSTGRES_BLOCKSCOUT_PASSWORD>@db.potos.internal:7432/blockscout
EXTERNAL_REDIS_URL=redis://db.potos.internal:6379/0
```

Start:

```bash
./start.sh backend
./start.sh microservices
```

### Host 3: Frontend (`web.potos.internal`)

Edit `.env`:

```
EXTERNAL_BACKEND_URL=http://app.potos.internal:4000
EXTERNAL_DATABASE_URL=postgresql://blockscout:<POSTGRES_BLOCKSCOUT_PASSWORD>@db.potos.internal:7432/blockscout
EXTERNAL_STATS_DB_URL=postgres://stats:<POSTGRES_STATS_PASSWORD>@db.potos.internal:7433/stats
```

Start:

```bash
./start.sh frontend
```

### Verification

From any reachable network position:

```bash
curl -sf http://web.potos.internal/api/v2/stats
```

---

## Active-standby / HA

For production uptime. Indexer must remain a singleton; API-only replicas scale horizontally.

### Topology

- **External managed Postgres** (primary + hot-standby, or managed service) — responsible for data replication / failover. Blockscout only consumes a `DATABASE_URL`.
- **External Redis** (Sentinel / cluster / managed).
- **N × `backend` instances**:
  - **Exactly one** has `DISABLE_INDEXER=false` (the active indexer)
  - All others have `DISABLE_INDEXER=true` (API-only readers)
- **N × `frontend` instances** behind an LB
- **Singleton `microservices` tier** (the `stats` and `user-ops-indexer` writers are also single-writer)
- **External nginx / HAProxy / cloud LB** in front of the backend replicas

### Running the active indexer

On `backend-active`:

```bash
# .env contains:
EXTERNAL_DATABASE_URL=postgresql://...@<primary-pg-lb>:5432/blockscout
EXTERNAL_REDIS_URL=redis://<redis-lb>:6379/0
DISABLE_INDEXER=false
```

```bash
./start.sh backend
```

### Running API-only replicas

On each `backend-api-N`:

```bash
# .env contains (note DISABLE_INDEXER=true):
EXTERNAL_DATABASE_URL=postgresql://...@<read-replica-lb>:5432/blockscout
EXTERNAL_REDIS_URL=redis://<redis-lb>:6379/0
DISABLE_INDEXER=true
```

```bash
./start.sh backend
```

API-only replicas can safely read from a PG read replica.

### Failover drill (active indexer dies)

1. **Verify**: current active is down (health check / log stop).
2. **Promote** a standby API replica to active:
   ```bash
   ssh backend-standby
   cd /opt/blockscout-potos
   sed -i 's/^DISABLE_INDEXER=true/DISABLE_INDEXER=false/' .env
   # If the DB URL was read-replica, repoint to primary:
   sed -i "s#@read-replica#@primary#" .env
   ./start.sh backend           # compose will recreate the container with new env
   ```
3. **Demote** the old active (if recovered) by reversing both changes.

Failover is currently manual. Automating it (watchdog + orchestration) belongs in your infra layer — outside the scope of this bundle.

### Scaling out API-only replicas

Replicas can be added dynamically:

```bash
# on a new host
tar -xzf output.tar.gz
# edit .env: set DISABLE_INDEXER=true and point EXTERNAL_DATABASE_URL to read replica
./start.sh backend
# add host to LB backend pool
```

Stats microservice should NOT be scaled out (single writer). Frontend/proxy can scale freely.

---

## Day-2 operations

### Health checks

```bash
# API
curl -sf http://<host>/api/v2/stats | jq .

# Backend container
docker compose -f potos.yml ps backend
docker compose -f potos.yml logs --tail=200 backend

# DB connection from backend
docker compose -f potos.yml exec backend bin/blockscout rpc "IO.inspect Explorer.Repo.query!(\"SELECT 1\")"
```

### Log locations

`backend` and `nft_media_handler` mount `./logs/` and `./dets/` into the working dir of their compose:

```
/opt/blockscout-potos/logs/
/opt/blockscout-potos/dets/
```

Check these for crash reports and DETS persistence files.

### Restarting a single service

```bash
docker compose -f potos.yml restart backend
docker compose -f potos.yml restart frontend
```

### Data migrations after an upgrade

Every `./start.sh all` (or `./start.sh backend`) triggers `Elixir.Explorer.ReleaseTasks.create_and_migrate()` (see `services/backend.yml` command). This runs pending Ecto migrations at startup. If the DB has diverged from the schema the backend expects, the container will crash-loop and the log will show `Ecto.Migration` errors.

---

## Troubleshooting

### Backend crash-loops immediately

Check:

```bash
docker compose -f potos.yml logs --tail=200 backend
```

Common causes:

| Log snippet | Cause |
|---|---|
| `DBConnection.ConnectionError` | DATABASE_URL wrong or DB unreachable |
| `[error] Postgrex.Protocol (...) failed to connect: ** (KeyError)` | Username/password mismatch |
| `Ecto.MigrationError` | Schema drift — DB was previously on a different blockscout version |
| `no route to host` | Firewall blocks container → DB |
| `undefined function Explorer.Chain...` | Stale image — rebuild bundle |

### `docker compose up` says "network blockscout-potos_default" can't be created

macOS Docker Desktop sometimes runs out of available subnets. Restart Docker Desktop, or:

```bash
docker network prune -f
./start.sh <tier>
```

### UI loads but pages are blank / 502

Check proxy → frontend plumbing:

```bash
docker compose -f potos.yml logs proxy
docker compose -f potos.yml exec proxy cat /etc/nginx/conf.d/default.conf
```

`proxy` reads template from `proxy/default.conf.template` and renders with env vars `BACK_PROXY_PASS` / `FRONT_PROXY_PASS`. If these point at wrong hosts, fix `.env` and `docker compose up -d proxy` to re-render.

### Indexer not advancing (`total_blocks` stays 0)

```bash
docker compose -f potos.yml logs -f backend | grep -i indexer
```

Common causes:

- `DISABLE_INDEXER=true` set accidentally
- `ETHEREUM_JSONRPC_HTTP_URL` unreachable from container (test: `docker compose -f potos.yml exec backend wget -qO- $ETHEREUM_JSONRPC_HTTP_URL`)
- Chain's first block not yet found by realtime fetcher — give it 60s, or kick catchup

### `stats` service complains about `STATS__DB_URL`

Multi-host layouts: make sure `EXTERNAL_STATS_DB_URL` points at the **stats-db** instance (port 7433 by default), not the main `blockscout` DB (port 7432).

---

## Upgrading to a newer upstream tag

Blockscout upstream tags release every 2-4 weeks. When a new `v10.3.x` or `v11.x.x` tag ships:

```bash
# 1. Fetch upstream
git fetch origin --tags
git tag -l 'v1*' --sort=-v:refname | head   # find target version, e.g. v10.3.0

# 2. Create new potos branch
git checkout -b potos/v10.3.0 v10.3.0

# 3. Cherry-pick the 5 potos commits from the previous release branch
git cherry-pick potos/v10.2.6~4..potos/v10.2.6
# (this is a range: 5 commits ending at the tip of potos/v10.2.6)

# 4. Resolve any rare conflicts — expected to be near zero since all additions
#    are in upstream-absent paths (docker-compose/potos/, package/, docs/potos/)

# 5. Validate
for f in potos potos-db potos-backend potos-microservices potos-frontend; do
  docker compose -f docker-compose/potos/$f.yml config >/dev/null && echo "$f OK" || echo "$f FAIL"
done

# 6. Rebuild bundle
cd package && ./package.sh

# 7. Push and tag
git push -u origin potos/v10.3.0
```

### What might break on upgrade

- **Upstream removes / renames a service** in `docker-compose/services/*.yml` → our tier compose files reference it via `extends:`, so break loudly at `docker compose config`. Action: update potos tier files to match.
- **Upstream changes env variable names** in `docker-compose/envs/common-*.env` → our templates still carry the old name. Action: diff `docker-compose/envs/common-blockscout.env` between versions and update `package/.env.template` + `package/deploy.config.example`.
- **New required env var** → same diff exercise; backend may crash-loop otherwise.
- **Dockerfile path change** → our tier compose files reference `dockerfile: ./docker/Dockerfile`; if upstream moves it, update `potos.yml` and `potos-backend.yml`.

Keep upgrade PRs small: one PR per minor version bump, rebuild bundle in CI to validate.

---

## Rollback

Blockscout's DB schema is forward-only in practice — rolling back the backend container without also rolling back the DB can leave the DB in a state newer than what the old backend expects. Two safe rollback strategies:

### Fast rollback (single-host, accepting reindex)

1. `./stop.sh all`
2. `docker volume rm <project>_blockscout-db-data <project>_stats-db-data` (drops all chain data)
3. Extract the **previous** bundle
4. `./start.sh all` — new DB, full reindex from the chain

### Slow rollback (DB snapshot based)

Requires having taken a Postgres base backup / snapshot before the upgrade.

1. `./stop.sh all` on every tier
2. Restore the pre-upgrade Postgres snapshot
3. Extract the previous bundle
4. `./start.sh all`

Plan for the slow rollback by scheduling Postgres snapshots (pg_basebackup / WAL archiving or your managed service's snapshot feature) prior to each upgrade. Out of scope for this bundle to automate.

---

## Quick reference

| Command | Purpose |
|---|---|
| `./package.sh` | Build bundle (from `package/` dir, with `deploy.config` present) |
| `./start.sh all` | Bring up all services on one host |
| `./start.sh <tier>` | Bring up a single tier (`db`, `backend`, `microservices`, `frontend`) |
| `./stop.sh <tier>` | Bring down the matching tier |
| `docker compose -f potos.yml ps` | Show running services |
| `docker compose -f potos.yml logs -f backend` | Follow backend logs |
| `docker compose -f potos.yml restart backend` | Restart one service |
| `docker compose -f potos.yml exec backend bin/blockscout remote` | Attach IEx remote shell to backend |

See also:
- `docker-compose/potos/README.md` — topology matrix, port map, cross-tier env vars
- `package/README.md` — packaging workflow
- `docs/superpowers/specs/2026-04-20-potos-v10.2.6-migration-design.md` — design rationale (on `master`)
