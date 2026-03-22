#!/bin/bash
set -euo pipefail

distdir="/workspace/distfiles"
mkdir -p "${distdir}"

urls=(
  "https://github.com/abseil/abseil-cpp/archive/20250814.1.tar.gz"
  "https://github.com/google/tcmalloc/archive/5da4a882003102fba0c0c0e8f6372567057332eb.tar.gz"
  "https://github.com/google/quiche/archive/1eb9b26af7a84f13ee208803c4704306b2ceec9a.tar.gz"
  "https://github.com/jk-jeon/dragonbox/archive/6c7c925b571d54486b9ffae8d9d18a822801cbda.zip"
  "https://github.com/simdutf/simdutf/releases/download/v7.3.4/singleheader.zip"
)

for url in "${urls[@]}"; do
  filename="${url##*/}"
  target="${distdir}/${filename}"

  if [[ -s "${target}" ]]; then
    echo "distfile cached: ${filename}"
    continue
  fi

  echo "prefetching distfile: ${filename}"
  curl --fail --location --retry 5 --retry-delay 5 --connect-timeout 30 --max-time 240 \
    --output "${target}" "${url}"
done
