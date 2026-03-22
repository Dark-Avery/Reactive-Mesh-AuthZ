#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/experiments/results/verify-mvp}"
PF_RECEIVER_PID=""
PF_ENVOY_PID=""
RECEIVER_PORT=""
ENVOY_PORT=""

cleanup() {
  if [[ -n "${PF_RECEIVER_PID}" ]] && kill -0 "${PF_RECEIVER_PID}" 2>/dev/null; then
    kill "${PF_RECEIVER_PID}" >/dev/null 2>&1 || true
    wait "${PF_RECEIVER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_ENVOY_PID}" ]] && kill -0 "${PF_ENVOY_PID}" 2>/dev/null; then
    kill "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
    wait "${PF_ENVOY_PID}" >/dev/null 2>&1 || true
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

mkdir -p "${OUTDIR}"

cd "${REPO_ROOT}"

./scripts/ensure_demo_idp_image.sh
kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/reactive" >/dev/null
kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/receiver -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/grpc-server -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/redis -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/envoy-reactive -n reactive-mesh-authz >/dev/null
kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/envoy-reactive -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli FLUSHDB >/dev/null

kubectl get pods,svc -n reactive-mesh-authz -o wide > "${OUTDIR}/cluster.txt"

./scripts/smoke_reactive.sh "${OUTDIR}/reactive-smoke.csv"
./scripts/verify_no_event_stability.sh "${OUTDIR}/no-event-stability.json"
python3 scripts/collect_overhead_snapshot.py "${OUTDIR}/overhead-reactive.json" --apps receiver,grpc-server,redis,envoy-reactive

pkill -f "kubectl port-forward .*svc/receiver .*:8080" >/dev/null 2>&1 || true
pkill -f "kubectl port-forward .*svc/envoy-reactive .*:9901" >/dev/null 2>&1 || true

RECEIVER_PORT="$(pick_port)"
ENVOY_PORT="$(pick_port)"

kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/receiver "${RECEIVER_PORT}:8080" > "${OUTDIR}/receiver-port-forward.log" 2>&1 &
PF_RECEIVER_PID=$!
sleep 2
curl -sf "http://127.0.0.1:${RECEIVER_PORT}/metrics" > "${OUTDIR}/receiver-metrics.txt"

kubectl port-forward --address 127.0.0.1 -n reactive-mesh-authz svc/envoy-reactive "${ENVOY_PORT}:9901" > "${OUTDIR}/envoy-port-forward.log" 2>&1 &
PF_ENVOY_PID=$!
sleep 2
curl -sf "http://127.0.0.1:${ENVOY_PORT}/stats" > "${OUTDIR}/envoy-stats.txt"
curl -sf "http://127.0.0.1:${ENVOY_PORT}/stats/prometheus" > "${OUTDIR}/envoy-stats-prometheus.txt"

./scripts/verify_oss_comparators.sh "${OUTDIR}/verify-oss-comparators"
./scripts/verify_push_baseline.sh "${OUTDIR}/verify-push-baseline"
./scripts/run_tla.sh > "${OUTDIR}/tla.txt"
python3 scripts/collect_overhead_snapshot.py "${OUTDIR}/overhead-baseline.json" --apps baseline-control,grpc-server,redis,envoy-baseline
python3 - "${OUTDIR}/overhead-reactive.json" "${OUTDIR}/overhead-baseline.json" "${OUTDIR}/overhead-snapshot.json" <<'PY'
import json
import pathlib
import sys

reactive = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
baseline = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[3])

merged = {
    "namespace": reactive.get("namespace") or baseline.get("namespace"),
    "sampling_interval_seconds": max(
        reactive.get("sampling_interval_seconds", 0.0),
        baseline.get("sampling_interval_seconds", 0.0),
    ),
    "apps": {},
}
merged["apps"].update(reactive.get("apps", {}))
merged["apps"].update(baseline.get("apps", {}))
out_path.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
python3 scripts/generate_correctness_report.py "${OUTDIR}" "${OUTDIR}/correctness-report.json" "${REPO_ROOT}/docs/evaluation/CORRECTNESS_REPORT.md"

python3 - "${OUTDIR}" <<'PY'
import csv
import json
import pathlib
import sys

outdir = pathlib.Path(sys.argv[1])
reactive_row = next(csv.DictReader((outdir / "reactive-smoke.csv").open(encoding="utf-8")))
no_event = json.loads((outdir / "no-event-stability.json").read_text(encoding="utf-8"))
oss_comparators = json.loads((outdir / "verify-oss-comparators" / "summary.json").read_text(encoding="utf-8"))
push_baseline = json.loads((outdir / "verify-push-baseline" / "summary.json").read_text(encoding="utf-8"))
receiver_metrics = (outdir / "receiver-metrics.txt").read_text(encoding="utf-8")
envoy_stats = (outdir / "envoy-stats.txt").read_text(encoding="utf-8")
envoy_stats_prom = (outdir / "envoy-stats-prometheus.txt").read_text(encoding="utf-8")
together_envoy_stats = envoy_stats + "\n" + envoy_stats_prom
tla_text = (outdir / "tla.txt").read_text(encoding="utf-8")
overhead = json.loads((outdir / "overhead-snapshot.json").read_text(encoding="utf-8"))
expected_issuer = "http://demo-idp:8080/realms/reactive-mesh"

required_receiver = [
    "receiver_events_total",
    "receiver_validation_failures_total",
]
required_envoy = [
    "reactive_pep.active_streams",
    "reactive_pep.pep_termination_total",
    "reactive_pep.post_revoke_deny_total",
]

summary = {
    "reactive_smoke_ok": (
        reactive_row["receiver_status"] == "200"
        and reactive_row["post_revoke_deny"] == "1"
        and float(reactive_row["latency_to_enforce_ms"]) >= 0.0
        and reactive_row["auth_flow"] == "demo-idp"
        and reactive_row["token_issuer"] == expected_issuer
    ),
    "no_event_stability_ok": (
        no_event["still_running_after_window"] is True
        and no_event["message_count"] > 0
        and no_event["token_issuer"] == expected_issuer
    ),
    "baseline_opa_ok": oss_comparators["baseline_opa_ok"] is True,
    "baseline_istio_custom_ok": oss_comparators["baseline_istio_custom_ok"] is True,
    "baseline_openfga_ok": oss_comparators["baseline_openfga_ok"] is True,
    "baseline_push_ok": push_baseline["baseline_push_ok"] is True,
    "receiver_metrics_ok": all(item in receiver_metrics for item in required_receiver),
    "envoy_metrics_ok": all(item in together_envoy_stats for item in required_envoy),
    "tla_ok": "Model checking completed. No error has been found." in tla_text,
    "overhead_ok": (
        overhead["apps"].get("envoy-reactive", {}).get("kubectl_top") is not None
        and overhead["apps"].get("envoy-baseline", {}).get("kubectl_top") is not None
    ),
}

(outdir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))

if not all(summary.values()):
    raise SystemExit("verify_mvp failed")
PY
