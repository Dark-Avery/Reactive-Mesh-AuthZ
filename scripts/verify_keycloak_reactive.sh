#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/experiments/results/verify-keycloak-reactive}"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.1.2}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-reactive-mesh-authz}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/reactive-mesh-docker-config}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"
mkdir -p "$OUTDIR"
mkdir -p "$DOCKER_CONFIG/buildx/activity"

PF_KEYCLOAK_PID=""
PF_RECEIVER_PID=""
PF_ENVOY_PID=""
KEYCLOAK_PORT=""
RECEIVER_PORT=""
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
  for pid in "$PF_KEYCLOAK_PID" "$PF_RECEIVER_PID" "$PF_ENVOY_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

if [[ ! -x "$CLIENT_BIN" ]]; then
  cmake -S "$REPO_ROOT/grpc" -B "$REPO_ROOT/grpc/build" >/dev/null
  cmake --build "$REPO_ROOT/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
fi

if ! docker image inspect "$KEYCLOAK_IMAGE" >/dev/null 2>&1; then
  docker pull "$KEYCLOAK_IMAGE" >/dev/null
fi
kind load docker-image "$KEYCLOAK_IMAGE" --name "$KIND_CLUSTER_NAME" >/dev/null

kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/reactive-keycloak" >/dev/null
kubectl rollout restart deployment/envoy-reactive -n reactive-mesh-authz >/dev/null
kubectl rollout status deployment/keycloak -n reactive-mesh-authz --timeout=240s >/dev/null
kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/envoy-reactive -n reactive-mesh-authz --timeout=180s >/dev/null

KEYCLOAK_PORT="$(pick_port)"
RECEIVER_PORT="$(pick_port)"
ENVOY_PORT="$(pick_port)"

kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/keycloak "${KEYCLOAK_PORT}:8080" >/tmp/reactive-mesh-keycloak-pf.log 2>&1 &
PF_KEYCLOAK_PID=$!
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-keycloak-receiver-pf.log 2>&1 &
PF_RECEIVER_PID=$!
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-reactive "${ENVOY_PORT}:8081" >/tmp/reactive-mesh-keycloak-envoy-pf.log 2>&1 &
PF_ENVOY_PID=$!
sleep 5

TOKEN="$("$REPO_ROOT/scripts/keycloak_get_token.sh" "http://127.0.0.1:${KEYCLOAK_PORT}")"

python3 - "$TOKEN" "$OUTDIR" "$CLIENT_BIN" "$RECEIVER_PORT" "$ENVOY_PORT" <<'PY'
import base64
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

token = sys.argv[1]
outdir = pathlib.Path(sys.argv[2])
client_bin = sys.argv[3]
receiver_port = sys.argv[4]
envoy_port = sys.argv[5]
outdir.mkdir(parents=True, exist_ok=True)

def b64url_decode(value):
    padding = '=' * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)

payload = json.loads(b64url_decode(token.split('.')[1]).decode())
sub = payload["sub"]
sid = payload["sid"]
jti = payload["jti"]

log_path = pathlib.Path("/tmp/reactive-mesh-keycloak-reactive.log")
with log_path.open("w", encoding="utf-8") as log:
    proc = subprocess.Popen(
        [client_bin, "--addr", f"127.0.0.1:{envoy_port}", "--bearer-token", token, "--interval", "200ms"],
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(1)
    revoke_ns = time.time_ns()
    req = urllib.request.Request(
        f"http://127.0.0.1:{receiver_port}/event",
        data=json.dumps({"event_type": "session-revoked", "sub": sub, "sid": sid, "jti": jti, "reason": "keycloak_smoke"}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        receiver_status = resp.status
        receiver_body = resp.read().decode()
    proc.wait(timeout=5)
    term_ns = time.time_ns()

reopen = subprocess.run(
    [client_bin, "--addr", f"127.0.0.1:{envoy_port}", "--bearer-token", token, "--interval", "200ms"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    timeout=5,
    check=False,
)
reopen_output = reopen.stdout

summary = {
    "sub": sub,
    "sid": sid,
    "jti": jti,
    "receiver_status": receiver_status,
    "receiver_body": receiver_body,
    "latency_to_enforce_ms": round((term_ns - revoke_ns) / 1_000_000, 3),
    "reopen_code": reopen.returncode,
    "reopen_output": reopen_output,
    "terminated_after_revoke": proc.returncode != 0,
    "reopen_denied": reopen.returncode != 0 and "seq=" not in reopen_output,
    "token_issuer": payload.get("iss"),
    "token_subject": payload.get("sub"),
}

(outdir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))

if not (summary["receiver_status"] == 200 and summary["terminated_after_revoke"] and summary["reopen_denied"]):
    raise SystemExit("verify_keycloak_reactive failed")
PY
