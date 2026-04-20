#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

OUTPUT_DIR="./output"
TARBALL="./output.tar.gz"
CONFIG="./deploy.config"

cleanup_on_fail() {
  echo "package.sh failed; cleaning up ${OUTPUT_DIR}" >&2
  rm -rf "$OUTPUT_DIR"
}
trap cleanup_on_fail ERR INT

# 1. Preconditions
if [ ! -f "$CONFIG" ]; then
  echo "error: $CONFIG not found" >&2
  echo "hint:  cp deploy.config.example deploy.config && edit it" >&2
  exit 1
fi
command -v docker    >/dev/null || { echo "docker not on PATH" >&2; exit 1; }
command -v envsubst  >/dev/null || { echo "envsubst not found (install gettext)" >&2; exit 1; }

# 2. Load config
set -a
# shellcheck disable=SC1090
source "$CONFIG"
set +a

: "${IMAGE_NAME:?IMAGE_NAME must be set in deploy.config}"
: "${RELEASE_VERSION:?RELEASE_VERSION must be set in deploy.config}"

# 3. Fresh output tree
rm -rf "$OUTPUT_DIR" "$TARBALL"
mkdir -p "$OUTPUT_DIR"/{services,envs,proxy}

# 4. Build the custom blockscout image (used by backend + nft_media_handler)
docker compose -f ../docker-compose/potos/potos.yml build backend

# 5. Save the built image
docker save -o "$OUTPUT_DIR/${IMAGE_NAME}.tar" "${IMAGE_NAME}:${RELEASE_VERSION}"

# 6. Copy potos tier compose files, rewriting paths for the flat output layout
for f in potos.yml potos-db.yml potos-backend.yml potos-microservices.yml potos-frontend.yml; do
  sed -e 's#\.\./services/#./services/#g' \
      -e 's#\.\./envs/#./envs/#g' \
      ../docker-compose/potos/"$f" > "$OUTPUT_DIR/$f"
done

# 7. Copy upstream service + env + proxy templates
cp ../docker-compose/services/*.yml "$OUTPUT_DIR/services/"
cp ../docker-compose/envs/*.env     "$OUTPUT_DIR/envs/"
cp ../docker-compose/proxy/*        "$OUTPUT_DIR/proxy/"

# 8. Render .env, start.sh, stop.sh
envsubst < .env.template       > "$OUTPUT_DIR/.env"
envsubst < start.sh.template   > "$OUTPUT_DIR/start.sh"
envsubst < stop.sh.template    > "$OUTPUT_DIR/stop.sh"
chmod +x "$OUTPUT_DIR/start.sh" "$OUTPUT_DIR/stop.sh"

# 9. Bundle
tar -czf "$TARBALL" -C "$OUTPUT_DIR" .
trap - ERR INT

echo "done: $TARBALL"
ls -lh "$TARBALL"
