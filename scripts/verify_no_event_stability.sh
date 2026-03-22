#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/experiments/results/no-event-stability.json}"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
PF_IDP_PID=""
PF_ENVOY_PID=""
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

cleanup() {
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

if [[ ! -x "$CLIENT_BIN" ]]; then
  cmake -S "$REPO_ROOT/grpc" -B "$REPO_ROOT/grpc/build" >/dev/null
  cmake --build "$REPO_ROOT/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
fi

pkill -f "kubectl port-forward .*svc/demo-idp .*:8080" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/envoy-reactive .*:8081" >/dev/null 2>&1 || true
IDP_PORT="$(pick_port)"
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/demo-idp "${IDP_PORT}:8080" >/tmp/reactive-mesh-no-event-idp-pf.log 2>&1 &
PF_IDP_PID=$!
ENVOY_PORT="$(pick_port)"
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-reactive "${ENVOY_PORT}:8081" >/tmp/reactive-mesh-no-event-envoy-pf.log 2>&1 &
PF_ENVOY_PID=$!
sleep 2

python3 - "$CLIENT_BIN" "$OUT" "$IDP_PORT" "$ENVOY_PORT" <<'PY'
import base64
import json
import pathlib
import subprocess
import sys
import time
import urllib.request
import urllib.parse

client_bin = sys.argv[1]
out_path = pathlib.Path(sys.argv[2])
idp_port = sys.argv[3]
envoy_port = sys.argv[4]
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
payload = json.loads(base64.urlsafe_b64decode(payload_segment.encode()).decode())
log_path = pathlib.Path("/tmp/reactive-mesh-no-event.log")
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
            payload["sub"],
            "--sid",
            payload["sid"],
            "--jti",
            payload["jti"],
            "--interval",
            "200ms",
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    time.sleep(5)
    still_running = proc.poll() is None
    line_count = sum(1 for line in log_path.read_text().splitlines() if "seq=" in line)
    if still_running:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

result = {
    "addr": f"127.0.0.1:{envoy_port}",
    "sub": payload["sub"],
    "sid": payload["sid"],
    "jti": payload["jti"],
    "token_issuer": payload.get("iss", ""),
    "duration_seconds": 5,
    "still_running_after_window": still_running,
    "message_count": line_count,
}

out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False))

if not still_running or line_count <= 0 or result["token_issuer"] != "http://demo-idp:8080/realms/reactive-mesh":
    raise SystemExit("verify_no_event_stability failed")
PY
