#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
MANIFEST="${TMP_DIR}/metrics-server.yaml"
PATCHED="${TMP_DIR}/metrics-server-patched.yaml"
URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
IMAGE="${METRICS_SERVER_IMAGE:-registry.k8s.io/metrics-server/metrics-server:v0.8.1}"
export IMAGE

current_kind_cluster() {
  local context
  context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "${context}" == kind-* ]]; then
    printf '%s\n' "${context#kind-}"
  fi
}

preload_kind_image() {
  local cluster_name
  cluster_name="${KIND_CLUSTER_NAME:-$(current_kind_cluster)}"
  if [[ -z "${cluster_name}" ]]; then
    return 0
  fi
  docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker pull "${IMAGE}" >/dev/null
  kind load docker-image "${IMAGE}" --name "${cluster_name}" >/dev/null
}

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

curl -fsSL -o "${MANIFEST}" "${URL}"
preload_kind_image

python3 - "${MANIFEST}" "${PATCHED}" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
dst = src.replace(
    "        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname\n",
    "        - --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP\n",
)
needle = "        - --metric-resolution=15s\n"
extra = "        - --kubelet-insecure-tls\n"
if extra not in dst:
    if needle in dst:
        dst = dst.replace(needle, needle + extra, 1)
    else:
        dst = dst.replace(
            "      containers:\n"
            "      - args:\n",
            "      containers:\n"
            "      - args:\n"
            "        - --kubelet-insecure-tls\n",
            1,
        )
dst = dst.replace(
    "        image: registry.k8s.io/metrics-server/metrics-server:v0.8.1\n",
    f"        image: {pathlib.os.environ['IMAGE']}\n"
    "        imagePullPolicy: IfNotPresent\n",
)
pathlib.Path(sys.argv[2]).write_text(dst, encoding="utf-8")
PY

kubectl apply -f "${PATCHED}"

rollout_ok=0
if kubectl rollout status deployment/metrics-server -n kube-system --timeout="${METRICS_SERVER_TIMEOUT:-300s}"; then
  rollout_ok=1
fi

for _ in $(seq 1 30); do
  if kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
    available="$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "${available}" == "True" ]]; then
      exit 0
    fi
  fi
  sleep 2
done

kubectl get pods -n kube-system -l k8s-app=metrics-server -o wide >&2 || true
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml >&2 || true
kubectl logs -n kube-system deploy/metrics-server --tail=200 >&2 || true
if [[ "${rollout_ok}" == "0" ]]; then
  echo "metrics-server rollout did not become ready in time" >&2
fi
echo "metrics-server APIService did not become Available in time" >&2
exit 1
