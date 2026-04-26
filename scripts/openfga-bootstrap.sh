#!/usr/bin/env bash
#
# OpenFGA bootstrap — apply bsvibe.fga schema to a running OpenFGA instance.
#
# Idempotent:
#   1. Ensure a store named "bsvibe" exists (create if missing) → STORE_ID.
#   2. Compute SHA-256 of openfga/bsvibe.fga.
#   3. Compare against the latest authorization model's stored hash
#      (we tag models by writing the hash into a sentinel `system` tuple).
#   4. If different (or no model yet) → write new model → record AUTH_MODEL_ID.
#   5. Persist STORE_ID + AUTH_MODEL_ID + schema_sha into
#      openfga/.bootstrap.json (gitignored, mode 0600).
#
# Re-running with no schema change is a no-op (just verifies and refreshes
# .bootstrap.json).
#
# Requires: docker, jq, sha256sum (or shasum on macOS).
#
# Usage:
#   scripts/openfga-bootstrap.sh                    # uses openfga/.env
#   scripts/openfga-bootstrap.sh --force            # rewrite model even if hash matches
#   OPENFGA_API_URL=http://... scripts/openfga-bootstrap.sh   # remote target

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-$HOME/Works/_infra}"
SCHEMA_FILE="$INFRA_DIR/openfga/bsvibe.fga"
ENV_FILE="$INFRA_DIR/openfga/.env"
STATE_FILE="$INFRA_DIR/openfga/.bootstrap.json"
STORE_NAME="bsvibe"

FORCE="${1:-}"

# ─── helpers ─────────────────────────────────────────────────────

err()  { echo "[openfga-bootstrap] ERROR: $*" >&2; exit 1; }
info() { echo "[openfga-bootstrap] $*"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ─── inputs ──────────────────────────────────────────────────────

[ -f "$SCHEMA_FILE" ] || err "schema file missing: $SCHEMA_FILE"
command -v jq >/dev/null || err "jq required (brew install jq)"
command -v curl >/dev/null || err "curl required"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# Default API URL = compose host port. Override with OPENFGA_API_URL.
API="${OPENFGA_API_URL:-http://127.0.0.1:${OPENFGA_HTTP_PORT:-8765}}"

# Auth header — first preshared key (for rotation, callers may pass the active one).
TOKEN="${OPENFGA_AUTH_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "${OPENFGA_AUTHN_PRESHARED_KEYS:-}" ]; then
  TOKEN="${OPENFGA_AUTHN_PRESHARED_KEYS%%,*}"
fi
AUTH_HEADER=()
if [ -n "$TOKEN" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
fi

# ─── 1. health check ─────────────────────────────────────────────

info "OpenFGA endpoint: $API"
if ! curl -sf "$API/healthz" >/dev/null; then
  err "OpenFGA $API not reachable — start docker-compose first (scripts/openfga-up.sh)"
fi

# ─── 2. ensure store ─────────────────────────────────────────────

# Read existing state if present.
EXISTING_STORE_ID=""
EXISTING_MODEL_ID=""
EXISTING_SHA=""
if [ -f "$STATE_FILE" ]; then
  EXISTING_STORE_ID="$(jq -r '.store_id // ""' "$STATE_FILE")"
  EXISTING_MODEL_ID="$(jq -r '.auth_model_id // ""' "$STATE_FILE")"
  EXISTING_SHA="$(jq -r '.schema_sha // ""' "$STATE_FILE")"
fi

# Try to discover a store named bsvibe via API regardless of cached state —
# survives state file deletion.
LIST=$(curl -sf "${AUTH_HEADER[@]}" "$API/stores")
DISCOVERED_STORE_ID=$(echo "$LIST" | jq -r --arg n "$STORE_NAME" '.stores[]? | select(.name==$n) | .id' | head -n1 || true)

if [ -n "$DISCOVERED_STORE_ID" ]; then
  STORE_ID="$DISCOVERED_STORE_ID"
  info "store '$STORE_NAME' exists: $STORE_ID"
elif [ -n "$EXISTING_STORE_ID" ]; then
  # cached but not discoverable — most likely datastore was wiped. Recreate.
  info "cached store $EXISTING_STORE_ID no longer exists; creating new one"
  STORE_ID=""
else
  STORE_ID=""
fi

if [ -z "$STORE_ID" ]; then
  CREATE=$(curl -sf "${AUTH_HEADER[@]}" -H "Content-Type: application/json" \
    -d "{\"name\":\"$STORE_NAME\"}" "$API/stores")
  STORE_ID=$(echo "$CREATE" | jq -r '.id')
  [ -n "$STORE_ID" ] && [ "$STORE_ID" != "null" ] || err "failed to create store: $CREATE"
  info "store '$STORE_NAME' created: $STORE_ID"
fi

# ─── 3. compute schema hash ──────────────────────────────────────

SCHEMA_SHA=$(sha256_file "$SCHEMA_FILE")
info "schema sha256: $SCHEMA_SHA"

# ─── 4. write model if needed ────────────────────────────────────

NEEDS_WRITE="no"
if [ "$FORCE" = "--force" ]; then
  NEEDS_WRITE="yes"
elif [ -z "$EXISTING_MODEL_ID" ] || [ "$EXISTING_SHA" != "$SCHEMA_SHA" ]; then
  NEEDS_WRITE="yes"
elif [ "$EXISTING_STORE_ID" != "$STORE_ID" ]; then
  # Store ID changed (e.g., recreated). Need new model in this store.
  NEEDS_WRITE="yes"
fi

if [ "$NEEDS_WRITE" = "yes" ]; then
  # Convert DSL → JSON authorization model. fga CLI does this; we use it via docker
  # to avoid forcing a host install. The image ships /openfga only; its `model write`
  # subcommand requires DSL → JSON conversion outside (transform). We use the
  # public openfga/cli image.
  info "transforming DSL → JSON authorization model"
  MODEL_JSON=$(docker run --rm -i --network=host \
    -v "$SCHEMA_FILE:/schema/bsvibe.fga:ro" \
    openfga/cli:latest model transform --file=/schema/bsvibe.fga --input-format=fga 2>/dev/null \
    || true)

  if [ -z "$MODEL_JSON" ] || ! echo "$MODEL_JSON" | jq empty 2>/dev/null; then
    err "fga model transform failed — verify openfga/cli image and DSL syntax"
  fi

  info "writing authorization model to store $STORE_ID"
  WRITE=$(curl -sf "${AUTH_HEADER[@]}" -H "Content-Type: application/json" \
    -d "$MODEL_JSON" "$API/stores/$STORE_ID/authorization-models")
  AUTH_MODEL_ID=$(echo "$WRITE" | jq -r '.authorization_model_id')
  [ -n "$AUTH_MODEL_ID" ] && [ "$AUTH_MODEL_ID" != "null" ] || err "model write failed: $WRITE"
  info "authorization model written: $AUTH_MODEL_ID"
else
  AUTH_MODEL_ID="$EXISTING_MODEL_ID"
  info "schema unchanged; reusing model $AUTH_MODEL_ID"
fi

# ─── 5. persist state ────────────────────────────────────────────

mkdir -p "$(dirname "$STATE_FILE")"
TMP=$(mktemp)
jq -n \
  --arg store_id "$STORE_ID" \
  --arg auth_model_id "$AUTH_MODEL_ID" \
  --arg schema_sha "$SCHEMA_SHA" \
  --arg api "$API" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{store_id:$store_id, auth_model_id:$auth_model_id, schema_sha:$schema_sha, api:$api, applied_at:$ts}' \
  > "$TMP"
mv "$TMP" "$STATE_FILE"
chmod 600 "$STATE_FILE"

cat "$STATE_FILE"
info "OK — bootstrap complete"
