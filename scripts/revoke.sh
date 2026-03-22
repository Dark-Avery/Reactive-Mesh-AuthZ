#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <sub> <sid> <jti> [receiver-url]" >&2
  exit 2
fi

sub="$1"
sid="$2"
jti="$3"
receiver_url="${4:-http://127.0.0.1:18080/event}"

payload="$(printf '{"event_type":"session-revoked","sub":"%s","sid":"%s","jti":"%s","reason":"manual_revoke"}' \
  "$sub" "$sid" "$jti")"

curl -sS -X POST "$receiver_url" \
  -H 'content-type: application/json' \
  -d "$payload"
echo
