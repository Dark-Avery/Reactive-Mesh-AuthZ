#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.0}"
TOOLS_DIR="${REPO_ROOT}/.tools/istio/${ISTIO_VERSION}"
ISTIOCTL="${TOOLS_DIR}/bin/istioctl"

if [[ -x "${ISTIOCTL}" ]]; then
  printf '%s\n' "${ISTIOCTL}"
  exit 0
fi

mkdir -p "${TOOLS_DIR}/bin"
tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

download_once() {
  (
    cd "${tmpdir}"
    curl --retry 6 --retry-delay 2 --retry-all-errors -fsSL https://istio.io/downloadIstio \
      | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh -
  )
}

for attempt in 1 2 3; do
  if download_once; then
    break
  fi
  if [[ "${attempt}" -eq 3 ]]; then
    echo "failed to download Istio ${ISTIO_VERSION} after ${attempt} attempts" >&2
    exit 1
  fi
  sleep 3
done

cp "${tmpdir}/istio-${ISTIO_VERSION}/bin/istioctl" "${ISTIOCTL}"
chmod +x "${ISTIOCTL}"
printf '%s\n' "${ISTIOCTL}"
