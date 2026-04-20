# Potos Blockscout — docker-compose deployment

This directory contains potos-specific compose files layered on top of upstream `v10.2.6`'s `docker-compose/services/*.yml` and `docker-compose/envs/*.env`.

## Files

| File | Purpose |
|---|---|
| `potos.yml` | All services on one host (dev / small deploy) |
| `potos-db.yml` | Persistence tier: `db`, `stats-db`, `redis-db` |
| `potos-backend.yml` | Backend tier: `backend` only (expects `EXTERNAL_DATABASE_URL`, `EXTERNAL_REDIS_URL`) |
| `potos-microservices.yml` | `visualizer`, `sig-provider`, `smart-contract-verifier`, `user-ops-indexer`, `nft_media_handler` |
| `potos-frontend.yml` | `frontend`, `stats`, `proxy` |

All `extends: file:` paths use `../services/` so these files run directly from the repo tree (`docker compose -f docker-compose/potos/potos.yml up`). The `package/` toolchain rewrites paths to the flat `output/` layout at packaging time.

## Topology matrix

| Hosts | Host 1 | Host 2 | Host 3 | Host 4 |
|---|---|---|---|---|
| 1 | `all` (`potos.yml`) | — | — | — |
| 2 | `db` | `backend` + `microservices` + `frontend` | — | — |
| 3 | `db` | `backend` + `microservices` | `frontend` | — |
| 4 | `db` | `backend` | `microservices` | `frontend` |
| HA | external PG/Redis | active `backend` + standby `backend` (`DISABLE_INDEXER=true`) + N × API-only `backend` | `microservices` | N × `frontend` behind LB |

## Port map

| Service | Container port | Default host port | Env override |
|---|---|---|---|
| proxy (HTTP) | 80 | 80 | — |
| backend (direct) | 4000 | 4000 | `BACKEND_PORT` |
| db | 5432 | 7432 | `DB_PORT` |
| stats-db | 5432 | 7433 | `STATS_DB_PORT` |
| redis-db | 6379 | 6379 | `REDIS_PORT` |
| smart-contract-verifier | 8050 | 8082 | `SCV_PORT` |
| sig-provider | 8050 | 8083 | `SIG_PROVIDER_PORT` |
| visualizer | 8050 | 8084 | `VISUALIZER_PORT` |

## Cross-tier environment variables

| Variable | Consumer tier | Value example |
|---|---|---|
| `EXTERNAL_DATABASE_URL` | backend, microservices (user-ops-indexer), frontend (stats) | `postgresql://blockscout:${POSTGRES_BLOCKSCOUT_PASSWORD}@db.potos.internal:7432/blockscout` |
| `EXTERNAL_REDIS_URL` | backend | `redis://redis.potos.internal:6379/0` |
| `EXTERNAL_BACKEND_URL` | frontend (proxy) | `http://backend.potos.internal:4000` |
| `EXTERNAL_STATS_DB_URL` | frontend (stats) | `postgres://stats:${POSTGRES_STATS_PASSWORD}@db.potos.internal:7433/stats` |
| `DISABLE_INDEXER` | backend | `true` on standby / API-only replicas |

## HA operational notes

- **Single indexer per chain**: run exactly one `backend` without `DISABLE_INDEXER`. All other backend replicas must set `DISABLE_INDEXER=true`.
- **Failover**: flip the env on the standby and `docker compose up -d` to restart. This is manual; orchestration belongs in your platform layer.
- **Stats microservice**: single writer per chain; run one instance.
- **Postgres / Redis HA**: out of scope. Point `EXTERNAL_DATABASE_URL` / `EXTERNAL_REDIS_URL` at an LB or managed service.
