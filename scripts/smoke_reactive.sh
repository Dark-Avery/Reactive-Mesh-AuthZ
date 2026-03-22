#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/experiments/results/reactive-smoke.csv}"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
PF_PID=""
PF_IDP_PID=""
PF_ENVOY_PID=""
RECEIVER_PORT=""
IDP_PORT=""
ENVOY_PORT=""

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
  for _ in $(seq 1 12); do
    if curl -sf "http://127.0.0.1:${RECEIVER_PORT}/health" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_grpc_path() {
  local log_file
  log_file="$(mktemp)"
  for _ in $(seq 1 12); do
    local token
    token="$("$REPO_ROOT/scripts/demo_idp_get_token.sh" "http://127.0.0.1:${IDP_PORT}")"
    set +e
    timeout 3s "${CLIENT_BIN}" \
      --addr "127.0.0.1:${ENVOY_PORT}" \
      --bearer-token "${token}" \
      --sub "warmup-sub" \
      --sid "warmup-sid" \
      --jti "warmup-jti" \
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
  for _ in $(seq 1 20); do
    local count
    count="$(kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli PUBSUB NUMSUB auth_events 2>/dev/null | awk 'NR==2 {print $1}' | tr -d '\r' || true)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= 1 )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_receiver_port_forward() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  RECEIVER_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-receiver-pf.log 2>&1 &
  PF_PID=$!
  sleep 2
}

start_idp_port_forward() {
  if [[ -n "${PF_IDP_PID}" ]] && kill -0 "${PF_IDP_PID}" 2>/dev/null; then
    kill "${PF_IDP_PID}" >/dev/null 2>&1 || true
    wait "${PF_IDP_PID}" >/dev/null 2>&1 || true
  fi
  IDP_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/demo-idp "${IDP_PORT}:8080" >/tmp/reactive-mesh-demo-idp-pf.log 2>&1 &
  PF_IDP_PID=$!
  sleep 2
}

start_envoy_port_forward() {
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  ENVOY_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-reactive "${ENVOY_PORT}:8081" >/tmp/reactive-mesh-envoy-reactive-pf.log 2>&1 &
  PF_ENVOY_PID=$!
  sleep 3
}

cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_IDP_PID}" ]] && kill -0 "${PF_IDP_PID}" 2>/dev/null; then
    kill "${PF_IDP_PID}" >/dev/null 2>&1 || true
    wait "${PF_IDP_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

pkill -f "kubectl port-forward .*svc/receiver .*:8080" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/demo-idp .*:8080" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/envoy-reactive .*:8081" >/dev/null 2>&1 || true

if [[ ! -x "$CLIENT_BIN" ]]; then
  cmake -S "$REPO_ROOT/grpc" -B "$REPO_ROOT/grpc/build" >/dev/null
  cmake --build "$REPO_ROOT/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
fi

start_idp_port_forward
start_receiver_port_forward
if ! wait_for_receiver_health; then
  start_receiver_port_forward
  if ! wait_for_receiver_health; then
    start_receiver_port_forward
    wait_for_receiver_health
  fi
fi

start_envoy_port_forward
if ! wait_for_grpc_path; then
  start_envoy_port_forward
  if ! wait_for_grpc_path; then
    start_envoy_port_forward
    wait_for_grpc_path
  fi
fi

wait_for_reactive_subscriber

python3 "$REPO_ROOT/bench/load-client/run_benchmark.py" \
  --client-binary "$CLIENT_BIN" \
  --grpc-addr "127.0.0.1:${ENVOY_PORT}" \
  --receiver-url "http://127.0.0.1:${RECEIVER_PORT}/event" \
  --mode reactive \
  --iterations 1 \
  --revoke-after-ms 1000 \
  --interval-ms 200 \
  --observe-after-revoke-ms 4000 \
  --token-url "http://127.0.0.1:${IDP_PORT}" \
  --event-match-fields "sid,jti" \
  --output "$OUT"

python3 - "$REPO_ROOT" "$CLIENT_BIN" "$ENVOY_PORT" "$RECEIVER_PORT" "$IDP_PORT" "$OUT" <<'PY'
import csv
import json
import subprocess
import sys

repo_root, client_bin, envoy_port, receiver_port, idp_port, out_path = sys.argv[1:]
expected_issuer = "http://demo-idp:8080/realms/reactive-mesh"

def load_row(path):
    return next(csv.DictReader(open(path, encoding="utf-8")))

def row_ok(row):
    latency = row.get("latency_to_enforce_ms", "")
    return (
        row["receiver_status"] == "200"
        and row["post_revoke_deny"] == "1"
        and row["still_running_after_observe"] == "0"
        and latency not in ("", None)
        and float(latency) >= 0.0
        and row["auth_flow"] == "demo-idp"
        and row["token_issuer"] == expected_issuer
    )

row = load_row(out_path)
if not row_ok(row):
    subprocess.run(
        [
            "python3",
            f"{repo_root}/bench/load-client/run_benchmark.py",
            "--client-binary", client_bin,
            "--grpc-addr", f"127.0.0.1:{envoy_port}",
            "--receiver-url", f"http://127.0.0.1:{receiver_port}/event",
            "--mode", "reactive",
            "--iterations", "1",
            "--revoke-after-ms", "1000",
            "--interval-ms", "200",
            "--observe-after-revoke-ms", "4000",
            "--token-url", f"http://127.0.0.1:{idp_port}",
            "--event-match-fields", "sid,jti",
            "--output", out_path,
        ],
        check=True,
    )
    row = load_row(out_path)

print(json.dumps(row, ensure_ascii=False))
if not row_ok(row):
    raise SystemExit("reactive smoke failed")
PY
