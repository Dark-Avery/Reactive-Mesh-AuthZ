#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${1:-$REPO_ROOT/experiments/results/verify-push-baseline}"

mkdir -p "${OUTDIR}"
cd "${REPO_ROOT}"

./scripts/ensure_demo_idp_image.sh
kubectl apply -k "${REPO_ROOT}/deploy/kustomize/overlays/baseline-push" >/dev/null
kubectl delete deployment/opa service/opa deployment/openfga service/openfga deployment/spicedb service/spicedb -n reactive-mesh-authz --ignore-not-found >/dev/null
kubectl rollout restart deployment/demo-idp -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/baseline-authz -n reactive-mesh-authz >/dev/null
kubectl rollout restart deployment/envoy-baseline -n reactive-mesh-authz >/dev/null
kubectl rollout status deployment/demo-idp -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/receiver -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/grpc-server -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/redis -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/baseline-authz -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl rollout status deployment/envoy-baseline -n reactive-mesh-authz --timeout=180s >/dev/null
kubectl exec -n reactive-mesh-authz deployment/redis -- redis-cli FLUSHDB >/dev/null

./scripts/smoke_baseline.sh "${OUTDIR}/baseline-push-smoke.json"

python3 - "${OUTDIR}" <<'PY'
import json
import pathlib
import sys

outdir = pathlib.Path(sys.argv[1])
push = json.loads((outdir / "baseline-push-smoke.json").read_text(encoding="utf-8"))

summary = {
    "baseline_push_ok": (
        push["still_running_after_revoke"] is True
        and push["post_lines"] > push["pre_lines"]
        and push["reopen_code"] != 0
        and push.get("reopen_streamed") is False
        and "\"source\":\"push-cache\"" in push["reopen_output"]
        and push["token_issuer"] == "http://demo-idp:8080/realms/reactive-mesh"
    )
}

out = outdir / "summary.json"
out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))

if not all(summary.values()):
    raise SystemExit("verify_push_baseline failed")
PY
