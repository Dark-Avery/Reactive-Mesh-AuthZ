#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_IDP_IMAGE="${DEMO_IDP_IMAGE:-reactive-mesh/demo-idp:v2}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-reactive-mesh-authz}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/reactive-mesh-docker-config}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"

mkdir -p "$DOCKER_CONFIG/buildx/activity"

docker build -t "$DEMO_IDP_IMAGE" "$REPO_ROOT/idp/demo" >/dev/null

kind load docker-image "$DEMO_IDP_IMAGE" --name "$KIND_CLUSTER_NAME" >/dev/null
