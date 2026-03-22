#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_CONFIG_PATH="${DOCKER_CONFIG:-${REPO_ROOT}/.tmp/docker-config}"
PLUGIN_DIR="${DOCKER_CONFIG_PATH}/cli-plugins"
PLUGIN_PATH="${PLUGIN_DIR}/docker-buildx"
SYSTEM_PLUGIN_PATH="/usr/libexec/docker/cli-plugins/docker-buildx"
BUILDX_VERSION="${BUILDX_VERSION:-v0.30.1}"
BUILDX_URL="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64"

mkdir -p "${PLUGIN_DIR}"

if docker buildx version >/dev/null 2>&1; then
  exit 0
fi

if [[ -x "${SYSTEM_PLUGIN_PATH}" ]]; then
  ln -sf "${SYSTEM_PLUGIN_PATH}" "${PLUGIN_PATH}"
  docker buildx version >/dev/null
  exit 0
fi

curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL "${BUILDX_URL}" -o "${PLUGIN_PATH}"
chmod +x "${PLUGIN_PATH}"
docker buildx version >/dev/null
