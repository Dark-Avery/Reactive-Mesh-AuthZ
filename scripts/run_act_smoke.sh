#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACT_CACHE_DIR="${REPO_ROOT}/.act-cache"

required_images=(
  reactive-mesh/receiver:dev
  reactive-mesh/grpc-server:dev
  reactive-mesh/redis:dev
  reactive-mesh/opa-envoy:dev
  reactive-mesh/envoy-reactive:dev
  reactive-mesh/envoy-baseline:dev
)

cd "${REPO_ROOT}"
mkdir -p "${ACT_CACHE_DIR}"
export XDG_CACHE_HOME="${ACT_CACHE_DIR}"

for image in "${required_images[@]}"; do
  docker image inspect "${image}" >/dev/null
done

kind delete cluster --name reactive-mesh-authz-act >/dev/null 2>&1 || true

exec act \
  -W .github/workflows/kind-smoke.yml \
  -j smoke \
  --artifact-server-path "${ACT_CACHE_DIR}/artifacts" \
  --env SKIP_IMAGE_BUILD=1 \
  --env SKIP_ARTIFACT_UPLOAD=1 \
  --env KIND_CLUSTER_NAME=reactive-mesh-authz-act \
  --env KIND_CONFIG=deploy/kind/kind-config-act.yaml \
  "$@"
