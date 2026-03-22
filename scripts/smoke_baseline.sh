#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/experiments/results/baseline-smoke.json}"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
PF_PID=""
PF_ENVOY_PID=""
PF_IDP_PID=""
RECEIVER_PORT=""
ENVOY_PORT=""
IDP_PORT=""

pick_port() {
  python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
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

wait_for_receiver_health() {
  for _ in $(seq 1 12); do
    if curl -sf "http://127.0.0.1:${RECEIVER_PORT}/health" >/dev/null; then
      return 0
    fi
    sleep 2
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

start_envoy_port_forward() {
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
  fi
  ENVOY_PORT="$(pick_port)"
  kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-baseline "${ENVOY_PORT}:8081" >/tmp/reactive-mesh-envoy-baseline-pf.log 2>&1 &
  PF_ENVOY_PID=$!
  sleep 3
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

pkill -f "kubectl port-forward .*svc/receiver .*:8080" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/envoy-baseline .*:8081" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/demo-idp .*:8080" >/dev/null 2>&1 || true

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

python3 - "$CLIENT_BIN" "$OUT" "$RECEIVER_PORT" "$ENVOY_PORT" "$IDP_PORT" <<'PY'
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request
import urllib.parse

client_bin = sys.argv[1]
out_path = pathlib.Path(sys.argv[2])
receiver_port = sys.argv[3]
envoy_port = sys.argv[4]
idp_port = sys.argv[5]
post_revoke_wait_seconds = float(os.getenv("POST_REVOKE_WAIT_SECONDS", "2"))
reopen_max_attempts = int(os.getenv("REOPEN_MAX_ATTEMPTS", "3"))
reopen_attempt_timeout_seconds = int(os.getenv("REOPEN_ATTEMPT_TIMEOUT_SECONDS", "5"))
reopen_retry_delay_seconds = float(os.getenv("REOPEN_RETRY_DELAY_SECONDS", "1"))
out_path.parent.mkdir(parents=True, exist_ok=True)

token_req = urllib.request.Request(
    f"http://127.0.0.1:{idp_port}/realms/reactive-mesh/protocol/openid-connect/token",
    data=urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "reactive-mesh-cli",
            "username": "alice",
            "password": "alice-pass",
        }
    ).encode(),
    headers={"content-type": "application/x-www-form-urlencoded"},
)
with urllib.request.urlopen(token_req, timeout=10) as resp:
    token = json.loads(resp.read().decode())["access_token"]

payload_segment = token.split(".")[1]
payload_segment += "=" * (-len(payload_segment) % 4)
token_payload = json.loads(base64.urlsafe_b64decode(payload_segment.encode()).decode())
sub = token_payload["sub"]
sid = token_payload["sid"]
jti = token_payload["jti"]
log_path = pathlib.Path("/tmp/reactive-mesh-baseline-smoke.log")
log_path.write_text("")

with log_path.open("w") as log:
    proc = subprocess.Popen(
        [
            client_bin,
            "--addr",
            f"127.0.0.1:{envoy_port}",
            "--bearer-token",
            token,
            "--sub",
            sub,
            "--sid",
            sid,
            "--jti",
            jti,
            "--interval",
            "200ms",
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    time.sleep(1)
    pre_lines = sum(1 for line in log_path.read_text().splitlines() if "seq=" in line)
    revoke_payload = json.dumps(
        {"event_type": "session-revoked", "sid": sid, "jti": jti, "reason": "baseline_smoke"}
    )
    revoke = subprocess.run(
        ["curl", "-sf", "-X", "POST", f"http://127.0.0.1:{receiver_port}/event", "-H", "content-type:application/json", "-d", revoke_payload],
        capture_output=True,
        text=True,
        check=True,
    )
    time.sleep(post_revoke_wait_seconds)
    post_lines = sum(1 for line in log_path.read_text().splitlines() if "seq=" in line)
    still_running = proc.poll() is None
    if still_running:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

reopen = None
reopen_output = ""
reopen_streamed = False
reopen_attempts = 0
for _ in range(reopen_max_attempts):
    reopen_attempts += 1
    reopen = subprocess.run(
        [
            "timeout",
            f"{reopen_attempt_timeout_seconds}s",
            client_bin,
            "--addr",
            f"127.0.0.1:{envoy_port}",
            "--bearer-token",
            token,
            "--sub",
            sub,
            "--sid",
            sid,
            "--jti",
            jti,
            "--interval",
            "200ms",
        ],
        capture_output=True,
        text=True,
    )
    reopen_output = reopen.stdout + reopen.stderr
    reopen_streamed = "seq=" in reopen_output
    if reopen.returncode != 0 and not reopen_streamed:
        break
    time.sleep(reopen_retry_delay_seconds)

result = {
    "pre_lines": pre_lines,
    "post_lines": post_lines,
    "still_running_after_revoke": still_running,
    "receiver_response": json.loads(revoke.stdout),
    "reopen_code": reopen.returncode,
    "reopen_output": reopen_output,
    "reopen_attempts": reopen_attempts,
    "token_issuer": token_payload.get("iss", ""),
}
result["reopen_streamed"] = reopen_streamed

out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False))

if not (still_running and post_lines > pre_lines and reopen.returncode != 0 and not reopen_streamed and result["token_issuer"] == "http://demo-idp:8080/realms/reactive-mesh"):
    raise SystemExit("baseline smoke failed")
PY
