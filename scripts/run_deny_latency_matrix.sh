#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
PROBE_BIN="$REPO_ROOT/bench/load-client/run_deny_latency_probe.py"
RESULTS_DIR="$REPO_ROOT/experiments/results/deny-latency"
ITERATIONS=30
MODES="reactive,baseline-ext_authz,baseline-poll,baseline-push"
REVOKE_AFTER_MS=250
PF_PID=""
PF_ENVOY_PID=""
PF_IDP_PID=""
RECEIVER_PORT=""
ENVOY_PORT=""
IDP_PORT=""

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

usage() {
  cat <<EOF
usage: $0 [--iterations N] [--modes csv] [--revoke-after-ms N]
EOF
}

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
    --revoke-after-ms)
      REVOKE_AFTER_MS="${2:?missing value}"
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

start_envoy_port_forward() {
  local mode="$1"
  local envoy_service="envoy-baseline"
  if [[ "$mode" == "reactive" ]]; then
    envoy_service="envoy-reactive"
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "kubectl port-forward .*svc/${envoy_service} .*:8081" >/dev/null 2>&1 || true
  ENVOY_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz "svc/${envoy_service}" "${ENVOY_PORT}:8081" >/tmp/reactive-mesh-deny-envoy-pf.log 2>&1 &
  PF_ENVOY_PID=$!
  sleep 3
}

restart_port_forwards() {
  local mode="$1"
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "kubectl port-forward .*svc/receiver .*:8080" >/dev/null 2>&1 || true
  pkill -f "kubectl port-forward .*svc/demo-idp .*:8080" >/dev/null 2>&1 || true
  RECEIVER_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-deny-receiver-pf.log 2>&1 &
  PF_PID=$!
  sleep 2
  if ! wait_for_receiver_health; then
    if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
      kill "${PF_PID}" >/dev/null 2>&1 || true
      wait "${PF_PID}" >/dev/null 2>&1 || true
    fi
    RECEIVER_PORT="$(pick_port)"
    kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-deny-receiver-pf.log 2>&1 &
    PF_PID=$!
    sleep 2
    wait_for_receiver_health
  fi
  IDP_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/demo-idp "${IDP_PORT}:8080" >/tmp/reactive-mesh-deny-idp-pf.log 2>&1 &
  PF_IDP_PID=$!
  sleep 2
  start_envoy_port_forward "$mode"
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
      kubectl delete deployment/envoy-baseline service/envoy-baseline deployment/opa service/opa deployment/baseline-authz service/baseline-authz deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
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
    *)
      echo "unknown mode: $mode" >&2
      exit 2
      ;;
  esac
}

mkdir -p "$RESULTS_DIR"
cd "$REPO_ROOT"

if [[ ! -x "$CLIENT_BIN" ]]; then
  cmake -S "$REPO_ROOT/grpc" -B "$REPO_ROOT/grpc/build" >/dev/null
  cmake --build "$REPO_ROOT/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
fi

IFS=',' read -r -a mode_list <<<"$MODES"
for mode in "${mode_list[@]}"; do
  deploy_mode "$mode"
  restart_port_forwards "$mode"
  if [[ "$mode" == "reactive" ]]; then
    wait_for_reactive_subscriber
  fi
  grpc_addr="127.0.0.1:${ENVOY_PORT}"
  if ! wait_for_grpc_path "$grpc_addr"; then
    start_envoy_port_forward "$mode"
    grpc_addr="127.0.0.1:${ENVOY_PORT}"
    wait_for_grpc_path "$grpc_addr"
  fi
  out_file="$RESULTS_DIR/${mode}.csv"
  echo "running deny-probe mode=$mode iterations=$ITERATIONS -> $out_file"
  python3 "$PROBE_BIN" \
    --client-binary "$CLIENT_BIN" \
    --grpc-addr "$grpc_addr" \
    --receiver-url "http://127.0.0.1:${RECEIVER_PORT}/event" \
    --mode "$mode" \
    --iterations "$ITERATIONS" \
    --revoke-after-ms "$REVOKE_AFTER_MS" \
    --token-url "http://127.0.0.1:${IDP_PORT}" \
    --event-match-fields "sid,jti" \
    --output "$out_file"
done

echo "deny latency matrix complete: $RESULTS_DIR"
