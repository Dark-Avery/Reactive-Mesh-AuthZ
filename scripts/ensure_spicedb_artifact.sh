#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SPICEDB_VERSION:-1.47.1}"
OUT_DIR="${REPO_ROOT}/deploy/images/spicedb"
OUT_FILE="${OUT_DIR}/spicedb_${VERSION}_linux_amd64.tar.gz"
URL="https://github.com/authzed/spicedb/releases/download/v${VERSION}/spicedb_${VERSION}_linux_amd64.tar.gz"

mkdir -p "${OUT_DIR}"

if [[ -s "${OUT_FILE}" ]]; then
  exit 0
fi

curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL -o "${OUT_FILE}" "${URL}"
