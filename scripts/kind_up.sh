#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="reactive"
SKIP_BUILD=0
SKIP_CLUSTER=0
FORCE_BUILD=0
CLUSTER_NAME="reactive-mesh-authz"
CLUSTER_CREATED=0
UPDATED_IMAGES=()
KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.tmp/kubeconfig}"
DOCKER_CONFIG_PATH="${DOCKER_CONFIG:-${REPO_ROOT}/.tmp/docker-config}"
BUILDX_CONFIG_PATH="${BUILDX_CONFIG:-${DOCKER_CONFIG_PATH}/buildx}"

usage() {
  cat <<EOF
usage: $0 [--mode reactive|baseline|baseline-poll|baseline-push|baseline-ext_authz|baseline-openfga|baseline-spicedb|both] [--skip-build] [--skip-cluster] [--force-build]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-cluster)
      SKIP_CLUSTER=1
      shift
      ;;
    --force-build)
      FORCE_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "reactive" && "$MODE" != "baseline" && "$MODE" != "baseline-poll" && "$MODE" != "baseline-push" && "$MODE" != "baseline-ext_authz" && "$MODE" != "baseline-openfga" && "$MODE" != "baseline-spicedb" && "$MODE" != "both" ]]; then
  echo "invalid mode: $MODE" >&2
  exit 2
fi

cd "$REPO_ROOT"
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
export KUBECONFIG="${KUBECONFIG_PATH}"
mkdir -p "${DOCKER_CONFIG_PATH}" "${BUILDX_CONFIG_PATH}"
export DOCKER_CONFIG="${DOCKER_CONFIG_PATH}"
export BUILDX_CONFIG="${BUILDX_CONFIG_PATH}"
"${REPO_ROOT}/scripts/ensure_buildx.sh"

NEED_POLL_BASELINE=0
NEED_OPA_BASELINE=0
NEED_OPENFGA_BASELINE=0
NEED_SPICEDB_BASELINE=0
case "$MODE" in
  baseline-poll)
    NEED_POLL_BASELINE=1
    ;;
  baseline-push)
    NEED_POLL_BASELINE=1
    ;;
  baseline-openfga)
    NEED_POLL_BASELINE=1
    NEED_OPENFGA_BASELINE=1
    ;;
  baseline-spicedb)
    NEED_POLL_BASELINE=1
    NEED_SPICEDB_BASELINE=1
    ;;
  baseline|baseline-ext_authz|both)
    NEED_OPA_BASELINE=1
    ;;
esac

latest_source_epoch() {
  find "$@" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -n1 | cut -d. -f1
}

cluster_has_image() {
  local image="$1"
  local cluster_ref="docker.io/${image}"
  local node

  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    if ! docker exec "$node" ctr -n k8s.io images ls -q | grep -qx "$cluster_ref"; then
      return 1
    fi
  done
  return 0
}

image_created_epoch() {
  local image="$1"
  local created
  created="$(docker image inspect -f '{{.Created}}' "$image" 2>/dev/null || true)"
  if [[ -z "$created" ]]; then
    echo 0
    return
  fi
  date -d "$created" +%s
}

needs_rebuild() {
  local image="$1"
  shift
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    return 0
  fi
  local source_epoch image_epoch
  source_epoch="$(latest_source_epoch "$@")"
  image_epoch="$(image_created_epoch "$image")"
  if [[ -z "$source_epoch" ]]; then
    return 0
  fi
  [[ "$image_epoch" -lt "$source_epoch" ]]
}

build_image_if_stale() {
  local image="$1"
  local dockerfile="$2"
  local build_args="$3"
  shift 3
  local paths=("$@")
  if needs_rebuild "$image" "${paths[@]}"; then
    echo "building $image"
    if [[ "$dockerfile" == "envoy/Dockerfile" ]]; then
      local envoy_config="envoy-reactive.yaml"
      if [[ "$build_args" == *"ENVOY_CONFIG="* ]]; then
        envoy_config="${build_args##*ENVOY_CONFIG=}"
        envoy_config="${envoy_config%% *}"
      fi
      "${REPO_ROOT}/scripts/build_envoy_image.sh" "$image" "$envoy_config"
    else
      # shellcheck disable=SC2086
      DOCKER_BUILDKIT=0 docker build -t "$image" -f "$dockerfile" $build_args .
    fi
    UPDATED_IMAGES+=("$image")
  else
    echo "reusing cached $image"
  fi
}

ensure_opa_image() {
  if [[ "$FORCE_BUILD" -eq 1 ]] || ! docker image inspect reactive-mesh/opa-envoy:dev >/dev/null 2>&1; then
    echo "refreshing reactive-mesh/opa-envoy:dev from official OPA envoy image"
    docker pull openpolicyagent/opa:latest-envoy-static >/dev/null
    docker tag openpolicyagent/opa:latest-envoy-static reactive-mesh/opa-envoy:dev
    UPDATED_IMAGES+=("reactive-mesh/opa-envoy:dev")
  else
    echo "reusing cached reactive-mesh/opa-envoy:dev"
  fi
}

ensure_openfga_image() {
  if needs_rebuild reactive-mesh/openfga:v1.12.1-dev deploy/images/openfga; then
    echo "building reactive-mesh/openfga:v1.12.1-dev from official OpenFGA release binary"
    DOCKER_BUILDKIT=0 docker build -f deploy/images/openfga/Dockerfile -t reactive-mesh/openfga:v1.12.1-dev .
    UPDATED_IMAGES+=("reactive-mesh/openfga:v1.12.1-dev")
  else
    echo "reusing cached reactive-mesh/openfga:v1.12.1-dev"
  fi
}

ensure_spicedb_image() {
  if needs_rebuild reactive-mesh/spicedb:v1.47.1-dev deploy/images/spicedb; then
    echo "building reactive-mesh/spicedb:v1.47.1-dev from official SpiceDB release binary"
    "${REPO_ROOT}/scripts/ensure_spicedb_artifact.sh"
    DOCKER_BUILDKIT=0 docker build -f deploy/images/spicedb/Dockerfile -t reactive-mesh/spicedb:v1.47.1-dev deploy/images/spicedb
    UPDATED_IMAGES+=("reactive-mesh/spicedb:v1.47.1-dev")
  else
    echo "reusing cached reactive-mesh/spicedb:v1.47.1-dev"
  fi
}

if [[ "$SKIP_CLUSTER" -eq 0 ]]; then
  if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
    kind create cluster --config deploy/kind/kind-config.yaml
    CLUSTER_CREATED=1
  fi
  kind export kubeconfig --name "$CLUSTER_NAME"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_image_if_stale reactive-mesh/receiver:dev receiver/Dockerfile "" \
    receiver common
  if [[ "$NEED_POLL_BASELINE" -eq 1 ]]; then
    build_image_if_stale reactive-mesh/baseline-authz:dev baseline/opa/Dockerfile "" \
      baseline common
  fi
  build_image_if_stale reactive-mesh/grpc-server:dev grpc/server/Dockerfile "" \
    grpc
  build_image_if_stale reactive-mesh/redis:dev deploy/images/redis/Dockerfile "" \
    deploy/images/redis
  build_image_if_stale reactive-mesh/envoy-reactive:dev envoy/Dockerfile "--build-arg ENVOY_CONFIG=envoy-reactive.yaml" \
    envoy envoy-custom pep grpc/proto
  if [[ "$NEED_OPA_BASELINE" -eq 1 ]]; then
    ensure_opa_image
  fi
  if [[ "$NEED_OPENFGA_BASELINE" -eq 1 ]]; then
    ensure_openfga_image
  fi
  if [[ "$NEED_SPICEDB_BASELINE" -eq 1 ]]; then
    ensure_spicedb_image
  fi
  baseline_before="$(docker image inspect -f '{{.Id}}' reactive-mesh/envoy-baseline:dev 2>/dev/null || true)"
  docker tag reactive-mesh/envoy-reactive:dev reactive-mesh/envoy-baseline:dev
  baseline_after="$(docker image inspect -f '{{.Id}}' reactive-mesh/envoy-baseline:dev 2>/dev/null || true)"
  if [[ "$baseline_before" != "$baseline_after" ]]; then
    UPDATED_IMAGES+=("reactive-mesh/envoy-baseline:dev")
  fi
fi

images=(
  reactive-mesh/receiver:dev
  reactive-mesh/grpc-server:dev
  reactive-mesh/redis:dev
  reactive-mesh/envoy-reactive:dev
  reactive-mesh/envoy-baseline:dev
)
if [[ "$NEED_POLL_BASELINE" -eq 1 ]]; then
  images+=(reactive-mesh/baseline-authz:dev)
fi
if [[ "$NEED_OPA_BASELINE" -eq 1 ]]; then
  images+=(reactive-mesh/opa-envoy:dev)
fi
if [[ "$NEED_OPENFGA_BASELINE" -eq 1 ]]; then
  images+=(reactive-mesh/openfga:v1.12.1-dev)
fi
if [[ "$NEED_SPICEDB_BASELINE" -eq 1 ]]; then
  images+=(reactive-mesh/spicedb:v1.47.1-dev)
fi

images_to_load=()
if [[ "$CLUSTER_CREATED" -eq 1 ]]; then
  images_to_load=("${images[@]}")
else
  declare -A seen_images=()
  for image in "${UPDATED_IMAGES[@]}"; do
    if [[ -z "${seen_images[$image]:-}" ]]; then
      images_to_load+=("$image")
      seen_images["$image"]=1
    fi
  done
  for image in "${images[@]}"; do
    if [[ -n "${seen_images[$image]:-}" ]]; then
      continue
    fi
    if ! cluster_has_image "$image"; then
      images_to_load+=("$image")
      seen_images["$image"]=1
    fi
  done
fi

if [[ "${#images_to_load[@]}" -gt 0 ]]; then
  kind load docker-image "${images_to_load[@]}" --name "$CLUSTER_NAME"
else
  echo "no image changes detected, skipping kind load"
fi

case "$MODE" in
  reactive)
    kubectl apply -k deploy/kustomize/overlays/reactive
    kubectl delete deployment/envoy-baseline service/envoy-baseline deployment/opa service/opa deployment/baseline-authz service/baseline-authz -n reactive-mesh-authz --ignore-not-found >/dev/null
    ;;
  baseline)
    kubectl apply -k deploy/kustomize/overlays/baseline
    kubectl delete deployment/baseline-authz service/baseline-authz -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  baseline-poll)
    kubectl apply -k deploy/kustomize/overlays/baseline-poll
    kubectl delete deployment/opa service/opa deployment/openfga service/openfga -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  baseline-push)
    kubectl apply -k deploy/kustomize/overlays/baseline-push
    kubectl delete deployment/opa service/opa deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  baseline-openfga)
    kubectl apply -k deploy/kustomize/overlays/baseline-openfga
    kubectl delete deployment/opa service/opa deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  baseline-spicedb)
    kubectl apply -k deploy/kustomize/overlays/baseline-spicedb
    kubectl delete deployment/opa service/opa deployment/openfga service/openfga -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  baseline-ext_authz)
    kubectl apply -k deploy/kustomize/overlays/baseline-ext-authz
    kubectl delete deployment/baseline-authz service/baseline-authz deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
  both)
    kubectl apply -k deploy/kustomize/overlays/reactive
    kubectl apply -k deploy/kustomize/overlays/baseline
    kubectl delete deployment/baseline-authz service/baseline-authz -n reactive-mesh-authz --ignore-not-found >/dev/null
    kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
    ;;
esac

kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null

case "$MODE" in
  reactive)
    kubectl rollout status deployment/envoy-reactive -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
  baseline|baseline-ext_authz)
    kubectl rollout status deployment/opa -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
  baseline-poll)
    kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
  baseline-push)
    kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
  baseline-openfga)
    kubectl rollout status deployment/openfga -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
  both)
    kubectl rollout status deployment/opa -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-reactive -n reactive-mesh-authz --timeout=180s >/dev/null
    kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
    ;;
esac

kubectl get pods,svc -n reactive-mesh-authz -o wide
