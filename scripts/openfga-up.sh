#!/usr/bin/env bash
#
# OpenFGA boot wrapper invoked by launchd (com.blas1n.openfga.plist).
#
# - Idempotent: `docker compose up -d` is a no-op if services are already running.
# - Reads secrets from openfga/.env (must exist; see openfga/.env.example).
# - Logs to logs/openfga.log via launchd redirection.
#
# Manual invocation also works:
#   ~/Works/_infra/scripts/openfga-up.sh

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-$HOME/Works/_infra}"
COMPOSE_FILE="$INFRA_DIR/docker-compose.openfga.yml"
ENV_FILE="$INFRA_DIR/openfga/.env"
LOG_DIR="$INFRA_DIR/logs"

mkdir -p "$LOG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "$(ts) [openfga-up] FATAL: $COMPOSE_FILE missing" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "$(ts) [openfga-up] FATAL: $ENV_FILE missing — copy openfga/.env.example and fill secrets" >&2
  exit 1
fi

# launchd PATH may not include /opt/homebrew/bin; ensure docker is reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v docker >/dev/null 2>&1; then
  echo "$(ts) [openfga-up] FATAL: docker CLI not in PATH" >&2
  exit 1
fi

echo "$(ts) [openfga-up] Starting OpenFGA stack"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

echo "$(ts) [openfga-up] up -d returned 0; current state:"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
