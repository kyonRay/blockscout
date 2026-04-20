# Potos Blockscout packaging

Produces `output.tar.gz` — a self-contained deployment bundle for the potos explorer.

## Prerequisites

- Docker with compose v2
- `envsubst` (package `gettext`)
- A built / pullable base image — `package.sh` builds from `../docker-compose/potos/potos.yml`

## Usage

```bash
cp deploy.config.example deploy.config
# edit deploy.config — at minimum set POSTGRES_*_PASSWORD and ETHEREUM_JSONRPC_HTTP_URL
./package.sh
# → writes ./output/ and ./output.tar.gz
```

## Deploying a bundle

On the target host:

```bash
mkdir blockscout && cd blockscout
tar -xzf output.tar.gz
./start.sh <tier>     # tier ∈ {all, db, backend, microservices, frontend}
```

`start.sh` loads `${IMAGE_NAME}.tar` into the local docker daemon if present, then `docker compose up --no-build --pull=missing -d` against the matching tier file.

Stop:

```bash
./stop.sh <tier>
```

## Multi-host deploy

On each host, extract the same bundle, edit `.env` to set `EXTERNAL_*` URLs pointing at the other hosts, then `./start.sh <tier>` with the tier that host serves. See `docker-compose/potos/README.md` for the topology matrix and env-var reference.

## Files produced in `output/`

```
output/
├── .env                 (rendered from .env.template)
├── start.sh             (rendered from start.sh.template, chmod +x)
├── stop.sh              (rendered from stop.sh.template,  chmod +x)
├── potos.yml
├── potos-db.yml
├── potos-backend.yml
├── potos-microservices.yml
├── potos-frontend.yml
├── ${IMAGE_NAME}.tar    (saved blockscout backend image)
├── services/*.yml       (upstream service definitions)
├── envs/*.env           (upstream default env files)
└── proxy/*              (upstream nginx config templates)
```

## Gitignored artifacts

- `deploy.config` (local secrets — never commit)
- `output/`, `output.tar.gz`, `*.tar`
