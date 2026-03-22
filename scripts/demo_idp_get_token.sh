#!/usr/bin/env bash
set -euo pipefail

DEMO_IDP_BASE_URL="${1:-http://127.0.0.1:18080}"
REALM="${DEMO_IDP_REALM:-reactive-mesh}"
CLIENT_ID="${DEMO_IDP_CLIENT_ID:-reactive-mesh-cli}"
USERNAME="${DEMO_IDP_USERNAME:-alice}"
PASSWORD="${DEMO_IDP_PASSWORD:-alice-pass}"

curl -fsS \
  -X POST "${DEMO_IDP_BASE_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "content-type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "username=${USERNAME}" \
  --data-urlencode "password=${PASSWORD}" \
| jq -r '.access_token'
