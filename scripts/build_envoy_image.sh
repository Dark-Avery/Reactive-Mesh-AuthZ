#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-reactive-mesh/envoy-reactive:dev}"
ENVOY_CONFIG="${2:-envoy-reactive.yaml}"
CACHE_ROOT="${REPO_ROOT}/.buildx-cache"
CACHE_DIR="${CACHE_ROOT}/$(echo "${IMAGE}" | tr '/:' '__')"
NEW_CACHE_DIR="${CACHE_DIR}-new"
DOCKER_CONFIG_PATH="${DOCKER_CONFIG:-${REPO_ROOT}/.tmp/docker-config}"
BUILDX_CONFIG_PATH="${BUILDX_CONFIG:-${DOCKER_CONFIG_PATH}/buildx}"

mkdir -p "${CACHE_ROOT}"
mkdir -p "${DOCKER_CONFIG_PATH}" "${BUILDX_CONFIG_PATH}"
rm -rf "${NEW_CACHE_DIR}"

cd "${REPO_ROOT}"
export DOCKER_CONFIG="${DOCKER_CONFIG_PATH}"
export BUILDX_CONFIG="${BUILDX_CONFIG_PATH}"
"${REPO_ROOT}/scripts/ensure_buildx.sh"

build_args=(
  --load
  -t "${IMAGE}"
  -f envoy/Dockerfile
  --build-arg "ENVOY_CONFIG=${ENVOY_CONFIG}"
)

driver="$(docker buildx ls 2>/dev/null | awk '/\*/ {print $2; exit}')"
cache_supported=1
if [[ "${driver}" == "docker" ]]; then
  cache_supported=0
fi

if [[ "${cache_supported}" -eq 1 ]]; then
  if [[ -d "${CACHE_DIR}" ]]; then
    build_args+=(--cache-from "type=local,src=${CACHE_DIR}")
  fi
  build_args+=(--cache-to "type=local,dest=${NEW_CACHE_DIR},mode=max")
fi
build_args+=(.)

docker buildx build "${build_args[@]}"

if [[ "${cache_supported}" -eq 1 && -d "${NEW_CACHE_DIR}" ]]; then
  rm -rf "${CACHE_DIR}"
  mv "${NEW_CACHE_DIR}" "${CACHE_DIR}"
fi
