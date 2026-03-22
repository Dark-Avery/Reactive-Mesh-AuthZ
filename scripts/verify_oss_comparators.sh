#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/experiments/results/verify-oss-comparators}"
INCLUDE_SPICEDB="${INCLUDE_SPICEDB:-0}"

mkdir -p "${OUTDIR}"
cd "${REPO_ROOT}"

if [[ "${INCLUDE_SPICEDB}" != "1" ]]; then
  rm -f "${OUTDIR}/baseline-spicedb-smoke.json"
fi

CLIENT_BIN="${REPO_ROOT}/grpc/build/grpc-client"
EXPECTED_ISSUER="http://demo-idp:8080/realms/reactive-mesh"

pick_port() {
  python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

ensure_client() {
  if [[ -x "${CLIENT_BIN}" ]]; then
    return 0
  fi
  cmake -S "${REPO_ROOT}/grpc" -B "${REPO_ROOT}/grpc/build" >/dev/null
  cmake --build "${REPO_ROOT}/grpc/build" --target grpc-client -j"$(nproc)" >/dev/null
}

wait_for_baseline_grpc() {
  ensure_client
  local grpc_port=""
  local pf_pid=""
  local pf_log=""
  local attempt
  local cycle
  local log_file
  log_file="$(mktemp)"

  start_forward() {
    if [[ -n "${pf_pid}" ]] && kill -0 "${pf_pid}" 2>/dev/null; then
      kill "${pf_pid}" >/dev/null 2>&1 || true
      wait "${pf_pid}" >/dev/null 2>&1 || true
    fi
    [[ -n "${pf_log}" ]] && rm -f "${pf_log}"
    grpc_port="$(pick_port)"
    pf_log="$(mktemp)"
    kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-baseline "${grpc_port}:8081" >"${pf_log}" 2>&1 &
    pf_pid=$!
    sleep 3
  }

  for cycle in $(seq 1 3); do
    start_forward
    for attempt in $(seq 1 12); do
      local suffix
      suffix="$(date +%s%N)"
      set +e
      timeout 3s "${CLIENT_BIN}" \
        --addr "127.0.0.1:${grpc_port}" \
        --sub "warmup-sub-${suffix}" \
        --sid "warmup-sid-${suffix}" \
        --jti "warmup-jti-${suffix}" \
        --interval 200ms >"${log_file}" 2>&1
      local rc=$?
      set -e
      if grep -q "seq=" "${log_file}" && [[ ${rc} -eq 0 || ${rc} -eq 124 ]]; then
        kill "${pf_pid}" >/dev/null 2>&1 || true
        wait "${pf_pid}" >/dev/null 2>&1 || true
        rm -f "${pf_log}"
        rm -f "${log_file}"
        return 0
      fi
      if ! kill -0 "${pf_pid}" 2>/dev/null; then
        break
      fi
      sleep 2
    done
  done

  [[ -n "${pf_log}" ]] && cat "${pf_log}" >&2
  cat "${log_file}" >&2
  if [[ -n "${pf_pid}" ]]; then
    kill "${pf_pid}" >/dev/null 2>&1 || true
    wait "${pf_pid}" >/dev/null 2>&1 || true
  fi
  [[ -n "${pf_log}" ]] && rm -f "${pf_log}"
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

deploy_opa() {
  ./scripts/ensure_demo_idp_image.sh
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-ext-authz" >/dev/null
  kubectl delete deployment/openfga service/openfga deployment/spicedb service/spicedb deployment/baseline-authz service/baseline-authz -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl delete svc envoy-baseline -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-ext-authz" >/dev/null
  kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/opa -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/opa -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli FLUSHDB >/dev/null
}

deploy_openfga() {
  ./scripts/ensure_demo_idp_image.sh
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-openfga" >/dev/null
  kubectl delete deployment/opa service/opa deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl delete svc envoy-baseline -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-openfga" >/dev/null
  kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/openfga -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/openfga -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli DEL openfga:store_id openfga:model_id >/dev/null 2>&1 || true
  kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
  wait_for_redis_key openfga:store_id
  wait_for_redis_key openfga:model_id
  kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli FLUSHDB >/dev/null
  kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
  wait_for_redis_key openfga:store_id
  wait_for_redis_key openfga:model_id
}

deploy_spicedb() {
  ./scripts/ensure_demo_idp_image.sh
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-spicedb" >/dev/null
  kubectl delete deployment/opa service/opa deployment/openfga service/openfga -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl delete svc envoy-baseline -n reactive-mesh-authz --ignore-not-found >/dev/null
  kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-spicedb" >/dev/null
  kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/spicedb -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/spicedb -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
  kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
  kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli FLUSHDB >/dev/null
  kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
  kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
  wait_for_receiver_log "receiver-cpp: SpiceDB initialized"
}

deploy_opa
./scripts/smoke_baseline.sh "${OUTDIR}/baseline-opa-smoke.json"

deploy_openfga
POST_REVOKE_WAIT_SECONDS=4 REOPEN_MAX_ATTEMPTS=8 REOPEN_ATTEMPT_TIMEOUT_SECONDS=3 REOPEN_RETRY_DELAY_SECONDS=2 \
  ./scripts/smoke_baseline.sh "${OUTDIR}/baseline-openfga-smoke.json"

./scripts/smoke_istio_custom.sh "${OUTDIR}/baseline-istio-custom-smoke.json"

if [[ "${INCLUDE_SPICEDB}" == "1" ]]; then
  deploy_spicedb
  ./scripts/smoke_baseline.sh "${OUTDIR}/baseline-spicedb-smoke.json"
fi

INCLUDE_SPICEDB="${INCLUDE_SPICEDB}" python3 - "${OUTDIR}" <<'PY'
import json
import os
import pathlib
import sys

outdir = pathlib.Path(sys.argv[1])
opa = json.loads((outdir / "baseline-opa-smoke.json").read_text(encoding="utf-8"))
openfga = json.loads((outdir / "baseline-openfga-smoke.json").read_text(encoding="utf-8"))
istio = json.loads((outdir / "baseline-istio-custom-smoke.json").read_text(encoding="utf-8"))
spicedb_path = outdir / "baseline-spicedb-smoke.json"
include_spicedb = os.environ.get("INCLUDE_SPICEDB") == "1"
spicedb = json.loads(spicedb_path.read_text(encoding="utf-8")) if include_spicedb and spicedb_path.exists() else None
expected_issuer = "http://demo-idp:8080/realms/reactive-mesh"

def ok(row):
    return (
        row["still_running_after_revoke"] is True
        and row["post_lines"] > row["pre_lines"]
        and row["reopen_code"] != 0
        and row.get("reopen_streamed") is False
        and row.get("token_issuer") == expected_issuer
    )

summary = {
    "baseline_opa_ok": ok(opa),
    "baseline_openfga_ok": ok(openfga),
    "baseline_istio_custom_ok": ok(istio),
}
if spicedb is not None:
    summary["baseline_spicedb_ok"] = ok(spicedb) and "\"source\":\"spicedb\"" in spicedb["reopen_output"]
out = outdir / "summary.json"
out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))

if not all(summary.values()):
    raise SystemExit("verify_oss_comparators failed")
PY
