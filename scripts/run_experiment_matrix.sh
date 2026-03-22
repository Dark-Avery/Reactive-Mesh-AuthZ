#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
RESULTS_DIR="$REPO_ROOT/experiments/results"
ITERATIONS=30
REVOKE_AFTER_MS=1000
OBSERVE_AFTER_REVOKE_MS=2000
MODES="reactive,baseline-ext_authz,baseline-istio-custom,baseline-openfga,baseline-poll,baseline-push"
PROFILES="low,medium,high"
PF_PID=""
PF_ENVOY_PID=""
PF_IDP_PID=""
RECEIVER_PORT=""
ENVOY_PORT=""
IDP_PORT=""

usage() {
  cat <<EOF
usage: $0 [--iterations N] [--modes csv] [--profiles csv] [--revoke-after-ms N] [--observe-after-revoke-ms N]
EOF
}

cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_IDP_PID}" ]] && kill -0 "${PF_IDP_PID}" 2>/dev/null; then
    kill "${PF_IDP_PID}" >/dev/null 2>&1 || true
    wait "${PF_IDP_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

pick_port() {
  python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

wait_for_receiver_health() {
  local attempt
  for attempt in $(seq 1 12); do
    if curl -sf "http://127.0.0.1:${RECEIVER_PORT}/health" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restart_port_forwards() {
  local mode="$1"
  local envoy_service="envoy-baseline"
  if [[ "$mode" == "reactive" ]]; then
    envoy_service="envoy-reactive"
  fi
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_IDP_PID}" ]] && kill -0 "${PF_IDP_PID}" 2>/dev/null; then
    kill "${PF_IDP_PID}" >/dev/null 2>&1 || true
    wait "${PF_IDP_PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "kubectl port-forward .*svc/receiver .*:8080" >/dev/null 2>&1 || true
  pkill -f "kubectl port-forward .*svc/demo-idp .*:8080" >/dev/null 2>&1 || true
  RECEIVER_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-matrix-receiver-pf.log 2>&1 &
  PF_PID=$!
  sleep 2
  if ! wait_for_receiver_health; then
    if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
      kill "${PF_PID}" >/dev/null 2>&1 || true
      wait "${PF_PID}" >/dev/null 2>&1 || true
    fi
    RECEIVER_PORT="$(pick_port)"
    kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-matrix-receiver-pf.log 2>&1 &
    PF_PID=$!
    sleep 2
    wait_for_receiver_health
  fi
  IDP_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/demo-idp "${IDP_PORT}:8080" >/tmp/reactive-mesh-matrix-idp-pf.log 2>&1 &
  PF_IDP_PID=$!
  sleep 2
  start_envoy_port_forward "$mode"
}

start_envoy_port_forward() {
  local mode="$1"
  local envoy_service="envoy-baseline"
  local namespace="reactive-mesh-authz"
  local remote_port="8081"
  if [[ "$mode" == "reactive" ]]; then
    envoy_service="envoy-reactive"
  elif [[ "$mode" == "baseline-istio-custom" ]]; then
    envoy_service="istio-ingressgateway"
    namespace="istio-system"
    remote_port="80"
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "kubectl port-forward .*svc/${envoy_service} .*:8081" >/dev/null 2>&1 || true
  ENVOY_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n "${namespace}" "svc/${envoy_service}" "${ENVOY_PORT}:${remote_port}" >/tmp/reactive-mesh-matrix-envoy-pf.log 2>&1 &
  PF_ENVOY_PID=$!
  sleep 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="${2:?missing value}"
      shift 2
      ;;
    --modes)
      MODES="${2:?missing value}"
      shift 2
      ;;
    --profiles)
      PROFILES="${2:?missing value}"
      shift 2
      ;;
    --revoke-after-ms)
      REVOKE_AFTER_MS="${2:?missing value}"
      shift 2
      ;;
    --observe-after-revoke-ms)
      OBSERVE_AFTER_REVOKE_MS="${2:?missing value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

profile_interval_ms() {
  case "$1" in
    low) echo 200 ;;
    medium) echo 50 ;;
    high) echo 10 ;;
    *)
      echo "unknown profile: $1" >&2
      exit 2
      ;;
  esac
}

wait_for_grpc_path() {
  local grpc_addr="$1"
  local log_file
  log_file="$(mktemp)"
  for _ in $(seq 1 12); do
    local token
    token="$("$REPO_ROOT/scripts/demo_idp_get_token.sh" "http://127.0.0.1:${IDP_PORT}")"
    set +e
    timeout 3s "${CLIENT_BIN}" \
      --addr "${grpc_addr}" \
      --bearer-token "${token}" \
      --interval 200ms >"${log_file}" 2>&1
    local rc=$?
    set -e
    if grep -q "seq=" "${log_file}" && [[ ${rc} -eq 0 || ${rc} -eq 124 ]]; then
      rm -f "${log_file}"
      return 0
    fi
    sleep 2
  done
  cat "${log_file}" >&2
  rm -f "${log_file}"
  return 1
}

wait_for_redis_key() {
  local key="$1"
  local attempt
  for attempt in $(seq 1 30); do
    local value
    value="$(kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli GET "$key" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$value" && "$value" != "(nil)" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_receiver_log() {
  local fragment="$1"
  local attempt
  for attempt in $(seq 1 30); do
    if kubectl logs -n reactive-mesh-authz deployment/receiver --tail=200 2>/dev/null | grep -Fq "$fragment"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_reactive_subscriber() {
  local attempt
  for attempt in $(seq 1 20); do
    local count
    count="$(kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli PUBSUB NUMSUB auth_events 2>/dev/null | awk 'NR==2 {print $1}' | tr -d '\r' || true)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 1 )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

deploy_mode() {
  local mode="$1"
  case "$mode" in
    reactive)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/reactive" >/dev/null
      kubectl delete deployment/envoy-baseline service/envoy-baseline deployment/opa service/opa deployment/baseline-authz service/baseline-authz -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-reactive -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    baseline-ext_authz)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-ext-authz" >/dev/null
      kubectl delete deployment/baseline-authz service/baseline-authz deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/opa -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    baseline-istio-custom)
      ./scripts/ensure_demo_idp_image.sh
      ./scripts/install_istio_custom.sh >/dev/null
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-istio-custom" >/dev/null
      kubectl delete deployment/envoy-baseline service/envoy-baseline deployment/envoy-reactive service/envoy-reactive deployment/opa service/opa deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/grpc-server -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/redis -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/istio-ingressgateway -n istio-system >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=180s >/dev/null
      ;;
    baseline-poll)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-poll" >/dev/null
      kubectl delete deployment/opa service/opa deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    baseline-push)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-push" >/dev/null
      kubectl delete deployment/opa service/opa deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    baseline-openfga)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-openfga" >/dev/null
      kubectl delete deployment/opa service/opa deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli DEL openfga:store_id openfga:model_id >/dev/null 2>&1 || true
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      wait_for_redis_key openfga:store_id
      wait_for_redis_key openfga:model_id
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/openfga -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    baseline-spicedb)
      ./scripts/ensure_demo_idp_image.sh
      kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-spicedb" >/dev/null
      kubectl delete deployment/opa service/opa deployment/openfga service/openfga -n reactive-mesh-authz --ignore-not-found >/dev/null
      kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/spicedb -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/spicedb -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
      kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
      kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
      wait_for_receiver_log "receiver-cpp: SpiceDB initialized"
      kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
      kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
      ;;
    *)
      echo "unknown mode: $mode" >&2
      exit 2
      ;;
  esac
}

grpc_addr_for_mode() {
  if [[ -z "${ENVOY_PORT}" ]]; then
    echo "envoy port-forward is not initialized" >&2
    exit 2
  fi
  echo "127.0.0.1:${ENVOY_PORT}"
}

cd "$REPO_ROOT"
mkdir -p "$RESULTS_DIR"

if [[ ! -x "$CLIENT_BIN" ]]; then
  cmake -S "$REPO_ROOT/grpc" -B "$REPO_ROOT/grpc/build" >/dev/null
  cmake --build "$REPO_ROOT/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
fi

IFS=',' read -r -a mode_list <<<"$MODES"
IFS=',' read -r -a profile_list <<<"$PROFILES"

for mode in "${mode_list[@]}"; do
  deploy_mode "$mode"
  restart_port_forwards "$mode"
  if [[ "$mode" == "reactive" ]]; then
    wait_for_reactive_subscriber
  fi
  grpc_addr="$(grpc_addr_for_mode "$mode")"
  if ! wait_for_grpc_path "$grpc_addr"; then
    start_envoy_port_forward "$mode"
    grpc_addr="$(grpc_addr_for_mode "$mode")"
    if ! wait_for_grpc_path "$grpc_addr"; then
      start_envoy_port_forward "$mode"
      grpc_addr="$(grpc_addr_for_mode "$mode")"
      wait_for_grpc_path "$grpc_addr"
    fi
  fi
  for profile in "${profile_list[@]}"; do
    interval_ms="$(profile_interval_ms "$profile")"
    out_file="$RESULTS_DIR/${mode}-${profile}.csv"
    echo "running mode=$mode profile=$profile interval_ms=$interval_ms iterations=$ITERATIONS -> $out_file"
    python3 "$REPO_ROOT/bench/load-client/run_benchmark.py" \
      --client-binary "$CLIENT_BIN" \
      --grpc-addr "$grpc_addr" \
      --receiver-url "http://127.0.0.1:${RECEIVER_PORT}/event" \
      --mode "$mode" \
      --iterations "$ITERATIONS" \
      --revoke-after-ms "$REVOKE_AFTER_MS" \
      --observe-after-revoke-ms "$OBSERVE_AFTER_REVOKE_MS" \
      --interval-ms "$interval_ms" \
      --token-url "http://127.0.0.1:${IDP_PORT}" \
      --event-match-fields "sid,jti" \
      --output "$out_file"
  done
done

echo "matrix complete: $RESULTS_DIR"
