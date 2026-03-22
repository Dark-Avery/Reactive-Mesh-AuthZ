#!/bin/bash
set -euo pipefail

attempt=1
max_attempts=3
log_dir=/workspace/build-logs

mkdir -p "${log_dir}"

while true; do
  log_file="${log_dir}/bazel-attempt-${attempt}.log"
  echo "Starting bazel build attempt ${attempt}/${max_attempts}"
  echo "Log file: ${log_file}"

  if CARGO_BAZEL_REPIN=true bazel build --noenable_bzlmod -c opt --distdir=/workspace/distfiles --jobs=16 --local_cpu_resources=16 --local_ram_resources=32768 //:envoy 2>&1 | tee "${log_file}"; then
    exit 0
  fi

  echo "Bazel build attempt ${attempt} failed. Tail of ${log_file}:"
  tail -n 200 "${log_file}" || true

  if [[ "${attempt}" -ge "${max_attempts}" ]]; then
    echo "Bazel build failed after ${max_attempts} attempts"
    exit 1
  fi

  echo "Bazel build attempt ${attempt} failed, retrying after transient fetch/build error"
  attempt=$((attempt + 1))
  sleep 5
done
