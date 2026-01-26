#!/bin/bash
set -euo pipefail

if [ -f .env ]; then
  source .env
fi

require_env() {
  if [ -z "${!1:-}" ]; then
    echo "Error: $1 is missing. Please check your .env file."
    exit 1
  fi
}

require_env GHCR_USER
require_env GHCR_TOKEN
require_env GHCR_OWNER
require_env GHCR_IMAGE

TARBALL="${1:-}"
REPO_URL="${2:-}"
BRANCH="${3:-}"
COMMIT="${4:-}"
TAG="${GHCR_TAG:-latest}"

if [ -z "$TARBALL" ]; then
  echo "Usage: $0 <tarball> [repo_url] [branch] [commit]"
  exit 1
fi

if [ ! -f "$TARBALL" ]; then
  echo "Error: Tarball not found: $TARBALL"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required but not found in PATH."
  exit 1
fi

OWNER_LC=$(echo "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')
IMAGE_LC=$(echo "$GHCR_IMAGE" | tr '[:upper:]' '[:lower:]')
IMAGE_NAME="ghcr.io/${OWNER_LC}/${IMAGE_LC}"
IMAGE_REF="${IMAGE_NAME}:${TAG}"

CHANGE_ARGS=()
if [ -n "$REPO_URL" ]; then
  CHANGE_ARGS+=(--change "LABEL org.opencontainers.image.source=$REPO_URL")
fi
if [ -n "$COMMIT" ]; then
  CHANGE_ARGS+=(--change "LABEL org.opencontainers.image.revision=$COMMIT")
fi
if [ -n "$BRANCH" ]; then
  CHANGE_ARGS+=(--change "LABEL org.opencontainers.image.ref.name=$BRANCH")
fi
CHANGE_ARGS+=(--change "LABEL org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")

echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

case "$TARBALL" in
  *.tar.xz)
    if ! command -v xz >/dev/null 2>&1; then
      echo "Error: xz is required to read $TARBALL"
      exit 1
    fi
    xz -dc "$TARBALL" | docker import "${CHANGE_ARGS[@]}" - "$IMAGE_REF"
    ;;
  *.tar.gz|*.tgz)
    if ! command -v gzip >/dev/null 2>&1; then
      echo "Error: gzip is required to read $TARBALL"
      exit 1
    fi
    gzip -dc "$TARBALL" | docker import "${CHANGE_ARGS[@]}" - "$IMAGE_REF"
    ;;
  *.tar)
    docker import "${CHANGE_ARGS[@]}" "$TARBALL" "$IMAGE_REF"
    ;;
  *)
    echo "Error: Unsupported tarball extension: $TARBALL"
    exit 1
    ;;
esac

docker push "$IMAGE_REF"
echo "Pushed $IMAGE_REF"
