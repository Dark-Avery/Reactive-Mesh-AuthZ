#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAL_DIR="$REPO_ROOT/formal/tla"
JAR_PATH="$FORMAL_DIR/tla2tools.jar"
RESULT_DIR="$FORMAL_DIR/results"
RESULT_FILE="$RESULT_DIR/tlc_run.txt"
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"

mkdir -p "$RESULT_DIR"

if [[ ! -f "$JAR_PATH" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "$JAR_PATH" "$TLA_URL"
fi

cd "$FORMAL_DIR"
java -cp "$JAR_PATH" tlc2.TLC -cleanup -deadlock -workers auto ReactiveMeshAuthZ.tla >"$RESULT_FILE" 2>&1
cat "$RESULT_FILE"
