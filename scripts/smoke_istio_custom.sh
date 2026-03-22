#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/experiments/results/istio-custom-smoke.json}"
CLIENT_BIN="$REPO_ROOT/grpc/build/grpc-client"
PF_IDP_PID=""
PF_RECEIVER_PID=""
PF_INGRESS_PID=""
IDP_PORT=""
RECEIVER_PORT=""
INGRESS_PORT=""

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
  for pid in "$PF_IDP_PID" "$PF_RECEIVER_PID" "$PF_INGRESS_PID"; do
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

"$REPO_ROOT/scripts/install_istio_custom.sh"

kubectl apply -k "$REPO_ROOT/deploy/kustomize/overlays/baseline-istio-custom" >/dev/null
kubectl delete deployment/envoy-baseline deployment/envoy-reactive deployment/opa deployment/openfga deployment/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
kubectl delete service/envoy-baseline service/envoy-reactive service/opa service/openfga service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
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

IDP_PORT="$(pick_port)"
RECEIVER_PORT="$(pick_port)"
INGRESS_PORT="$(pick_port)"
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/demo-idp "${IDP_PORT}:8080" >/tmp/reactive-mesh-istio-idp-pf.log 2>&1 &
PF_IDP_PID=$!
kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" >/tmp/reactive-mesh-istio-receiver-pf.log 2>&1 &
PF_RECEIVER_PID=$!
kubectl port-forward --address 127.0.0.1 -n istio-system svc/istio-ingressgateway "${INGRESS_PORT}:80" >/tmp/reactive-mesh-istio-ingress-pf.log 2>&1 &
PF_INGRESS_PID=$!
sleep 5

python3 - "$CLIENT_BIN" "$OUT" "$RECEIVER_PORT" "$INGRESS_PORT" "$IDP_PORT" <<'PY'
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
receiver_port = sys.argv[3]
ingress_port = sys.argv[4]
idp_port = sys.argv[5]
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
log_path = pathlib.Path("/tmp/reactive-mesh-istio-smoke.log")
log_path.write_text("")

for _ in range(10):
    warmup = subprocess.run(
        ["timeout", "3s", client_bin, "--addr", f"127.0.0.1:{ingress_port}", "--bearer-token", token, "--interval", "200ms"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if "seq=" in warmup.stdout:
        break
    time.sleep(2)
else:
    raise SystemExit(f"istio warmup failed: {warmup.stdout}")

with log_path.open("w") as log:
    proc = subprocess.Popen(
        [client_bin, "--addr", f"127.0.0.1:{ingress_port}", "--bearer-token", token, "--interval", "200ms"],
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(1)
    pre_lines = sum(1 for line in log_path.read_text().splitlines() if "seq=" in line)
    req = urllib.request.Request(
        f"http://127.0.0.1:{receiver_port}/event",
        data=json.dumps({"event_type": "session-revoked", "sub": sub, "sid": sid, "jti": jti, "reason": "istio_custom_smoke"}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        receiver_status = resp.status
        receiver_body = resp.read().decode()
    time.sleep(2)
    post_lines = sum(1 for line in log_path.read_text().splitlines() if "seq=" in line)
    still_running = proc.poll() is None
    if still_running:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

reopen = subprocess.run(
    ["timeout", "5s", client_bin, "--addr", f"127.0.0.1:{ingress_port}", "--bearer-token", token, "--interval", "200ms"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    check=False,
)
reopen_output = reopen.stdout
reopen_streamed = "seq=" in reopen_output

summary = {
    "mode": "baseline-istio-custom",
    "sub": sub,
    "sid": sid,
    "jti": jti,
    "receiver_status": receiver_status,
    "receiver_body": receiver_body,
    "pre_lines": pre_lines,
    "post_lines": post_lines,
    "still_running_after_revoke": still_running,
    "reopen_code": reopen.returncode,
    "reopen_output": reopen_output,
    "reopen_streamed": reopen_streamed,
    "reopen_denied": reopen.returncode != 0 and not reopen_streamed,
    "token_issuer": token_payload.get("iss"),
    "auth_flow": "demo-idp",
}

out_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))

if not (summary["receiver_status"] == 200 and still_running and post_lines > pre_lines and summary["reopen_denied"]):
    raise SystemExit("smoke_istio_custom failed")
PY
