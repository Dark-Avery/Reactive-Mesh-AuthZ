#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-reactive-mesh-authz}"
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-/tmp/reactive-mesh-helm/config}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-/tmp/reactive-mesh-helm/cache}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-/tmp/reactive-mesh-helm/data}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/reactive-mesh-docker-config}"
mkdir -p "${HELM_CONFIG_HOME}" "${HELM_CACHE_HOME}" "${HELM_DATA_HOME}"
mkdir -p "${DOCKER_CONFIG}/buildx/activity"

pull_and_load() {
  local image="$1"
  local attempt
  for attempt in 1 2 3; do
    if docker pull "${image}" >/dev/null && kind load docker-image "${image}" --name "${KIND_CLUSTER_NAME}" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "failed to pull/load image: ${image}" >&2
  return 1
}

release_exists() {
  local name="$1"
  helm status "${name}" -n istio-system >/dev/null 2>&1
}

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null

pull_and_load "docker.io/istio/pilot:${ISTIO_VERSION}"
pull_and_load "docker.io/istio/proxyv2:${ISTIO_VERSION}"

if ! release_exists istio-base; then
  helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version "${ISTIO_VERSION}" --wait >/dev/null
fi

if ! release_exists istiod; then
  helm upgrade --install istiod istio/istiod \
    --version "${ISTIO_VERSION}" \
    -n istio-system \
    -f "${REPO_ROOT}/deploy/istio/istiod-values.yaml" \
    --wait >/dev/null
fi

if ! release_exists istio-ingressgateway; then
  helm upgrade --install istio-ingressgateway istio/gateway \
    --version "${ISTIO_VERSION}" \
    -n istio-system \
    --set service.type=ClusterIP \
    --wait >/dev/null
fi

kubectl patch deployment istio-ingressgateway -n istio-system --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
kubectl rollout restart deployment/istio-ingressgateway -n istio-system >/dev/null

kubectl rollout status deployment/istiod -n istio-system --timeout=300s >/dev/null
kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=300s >/dev/null
kubectl get svc -n istio-system istio-ingressgateway >/dev/null
