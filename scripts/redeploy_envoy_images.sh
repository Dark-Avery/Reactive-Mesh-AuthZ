#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-reactive-mesh-authz}"
NAMESPACE="${NAMESPACE:-reactive-mesh-authz}"

cd "${REPO_ROOT}"

docker image inspect reactive-mesh/envoy-reactive:dev >/dev/null
docker tag reactive-mesh/envoy-reactive:dev reactive-mesh/envoy-baseline:dev

kind load docker-image \
  reactive-mesh/envoy-reactive:dev \
  reactive-mesh/envoy-baseline:dev \
  --name "${CLUSTER_NAME}"

kubectl rollout restart deployment/envoy-reactive -n "${NAMESPACE}"
kubectl rollout restart deployment/envoy-baseline -n "${NAMESPACE}"
kubectl rollout status deployment/envoy-reactive -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/envoy-baseline -n "${NAMESPACE}" --timeout=300s
kubectl get pods -n "${NAMESPACE}" -o wide | rg 'envoy-(reactive|baseline)'
