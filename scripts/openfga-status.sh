#!/usr/bin/env bash
#
# OpenFGA health + applied schema summary.
#
# Output (human-readable lines, suitable for `_infra/scripts/status.sh` integration):
#   endpoint    http://127.0.0.1:8765
#   health      OK
#   store_id    01HABCDEF...
#   model_id    01HABCDEG...
#   schema_sha  9c0a...
#   applied_at  2026-04-25T12:34:56Z
#
# Exit code:
#   0 = healthy + bootstrap state present
#   1 = endpoint unreachable
#   2 = bootstrap state missing or stale (run scripts/openfga-bootstrap.sh)

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-$HOME/Works/_infra}"
ENV_FILE="$INFRA_DIR/openfga/.env"
STATE_FILE="$INFRA_DIR/openfga/.bootstrap.json"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

API="${OPENFGA_API_URL:-http://127.0.0.1:${OPENFGA_HTTP_PORT:-8765}}"

TOKEN="${OPENFGA_AUTH_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "${OPENFGA_AUTHN_PRESHARED_KEYS:-}" ]; then
  TOKEN="${OPENFGA_AUTHN_PRESHARED_KEYS%%,*}"
fi
AUTH_HEADER=()
[ -n "$TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")

printf '%-12s %s\n' "endpoint" "$API"

if ! curl -sf "$API/healthz" >/dev/null; then
  printf '%-12s %s\n' "health" "DOWN"
  exit 1
fi
printf '%-12s %s\n' "health" "OK"

if [ ! -f "$STATE_FILE" ]; then
  printf '%-12s %s\n' "state" "missing — run scripts/openfga-bootstrap.sh"
  exit 2
fi

STORE_ID=$(jq -r '.store_id' "$STATE_FILE")
MODEL_ID=$(jq -r '.auth_model_id' "$STATE_FILE")
SHA=$(jq -r '.schema_sha' "$STATE_FILE")
APPLIED=$(jq -r '.applied_at' "$STATE_FILE")

printf '%-12s %s\n' "store_id" "$STORE_ID"
printf '%-12s %s\n' "model_id" "$MODEL_ID"
printf '%-12s %s\n' "schema_sha" "$SHA"
printf '%-12s %s\n' "applied_at" "$APPLIED"

# Verify the model still exists in OpenFGA (catches datastore wipe).
RESP=$(curl -sf "${AUTH_HEADER[@]}" "$API/stores/$STORE_ID/authorization-models/$MODEL_ID" || true)
if echo "$RESP" | jq -e '.authorization_model.id' >/dev/null 2>&1; then
  printf '%-12s %s\n' "remote" "OK"
else
  printf '%-12s %s\n' "remote" "MISSING — re-run scripts/openfga-bootstrap.sh"
  exit 2
fi
