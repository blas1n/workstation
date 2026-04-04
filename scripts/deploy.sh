#!/usr/bin/env bash
#
# BSVibe Unified Deploy Script
#
# Usage:
#   ./deploy.sh              # Deploy all projects
#   ./deploy.sh bsgateway    # Deploy single project
#   ./deploy.sh --status     # Show deployment status
#
# This script handles:
#   1. Git pull (fast-forward)
#   2. Database migration (alembic)
#   3. Docker Compose build + restart
#   4. Health check verification
#
# Prerequisites:
#   - Docker + Docker Compose
#   - uv (Python package manager)
#   - Projects set up with bare repo + worktree pattern

set -euo pipefail

WORKS_DIR="$HOME/Works"
LOG_DIR="$WORKS_DIR/_infra/logs"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d).log"

mkdir -p "$LOG_DIR"

# Project definitions: name|compose_project|compose_file|health_url|has_alembic|has_frontend
declare -a PROJECTS=(
  "BSGateway|bsgateway|deploy/docker-compose.yml|http://localhost:4000/health|yes|yes"
  "BSNexus|bsnexus|deploy/docker-compose.yml|http://localhost:8100/health|yes|yes"
  "BSupervisor|bsupervisor|deploy/docker-compose.yml|http://localhost:8500/api/health|yes|no"
  "BSage|bsage|deploy/docker-compose.yml|http://localhost:8400/api/health|no|yes"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
  echo "$msg" >> "$LOG_FILE"
  echo -e "$1"
}

check_health() {
  local url="$1"
  local retries=10
  local wait=3

  for i in $(seq 1 $retries); do
    if curl -sf "$url" > /dev/null 2>&1; then
      return 0
    fi
    sleep $wait
  done
  return 1
}

deploy_project() {
  local IFS='|'
  read -r name compose_project compose_file health_url has_alembic has_frontend <<< "$1"

  local work_dir="$WORKS_DIR/$name/main"
  local bare_dir="$WORKS_DIR/$name/.bare"
  local compose_path="$work_dir/$compose_file"

  log "${BLUE}━━━ Deploying $name ━━━${NC}"

  # Check project exists
  if [ ! -d "$work_dir" ]; then
    log "${RED}  SKIP — $work_dir not found${NC}"
    return 1
  fi

  # Git pull
  if [ -d "$bare_dir" ]; then
    git -C "$bare_dir" fetch origin main --quiet 2>/dev/null || true
    local local_rev=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null)
    local remote_rev=$(git -C "$bare_dir" rev-parse origin/main 2>/dev/null)

    if [ "$local_rev" = "$remote_rev" ]; then
      log "${YELLOW}  Already up to date (${local_rev:0:7})${NC}"
    else
      log "  Pulling ${remote_rev:0:7}..."
      if ! git -C "$work_dir" merge origin/main --ff-only 2>> "$LOG_FILE"; then
        log "${RED}  Merge failed — resolve conflicts manually${NC}"
        return 1
      fi
      log "${GREEN}  Merged ${local_rev:0:7} → ${remote_rev:0:7}${NC}"
    fi
  fi

  # Docker Compose build + up
  if [ -f "$compose_path" ]; then
    log "  Building and starting containers..."
    if docker compose -p "$compose_project" -f "$compose_path" up -d --build >> "$LOG_FILE" 2>&1; then
      log "${GREEN}  Containers started${NC}"
    else
      log "${RED}  Container build/start failed${NC}"
      return 1
    fi

  # Database migration (run inside container after build)
  if [ "$has_alembic" = "yes" ]; then
    log "  Running database migration..."
    if docker compose -p "$compose_project" -f "$compose_path" run --rm --no-deps app python -m alembic upgrade head >> "$LOG_FILE" 2>&1; then
      log "${GREEN}  Migration complete${NC}"
    else
      log "${RED}  Migration failed — check logs${NC}"
      return 1
    fi
  fi
  fi

  # Health check
  log "  Waiting for health check..."
  if check_health "$health_url"; then
    log "${GREEN}  ✓ $name is healthy${NC}"
  else
    log "${RED}  ✗ $name health check failed ($health_url)${NC}"
    return 1
  fi

  log ""
}

show_status() {
  echo -e "${BLUE}━━━ BSVibe Deployment Status ━━━${NC}"
  echo ""

  for project_def in "${PROJECTS[@]}"; do
    local IFS='|'
    read -r name compose_project compose_file health_url _ _ <<< "$project_def"

    local work_dir="$WORKS_DIR/$name/main"
    local rev=$(git -C "$work_dir" rev-parse --short HEAD 2>/dev/null || echo "???")
    local branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || echo "???")

    # Health check
    if curl -sf "$health_url" > /dev/null 2>&1; then
      local status="${GREEN}●${NC} UP"
    else
      local status="${RED}●${NC} DOWN"
    fi

    # Container status
    local containers=$(docker compose -p "$compose_project" -f "$work_dir/$compose_file" ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | tail -n +2 || echo "not running")

    printf "  %-15s %b  rev=%s  branch=%s\n" "$name" "$status" "$rev" "$branch"
  done

  echo ""
}

# ─── Main ───

if [ "${1:-}" = "--status" ]; then
  show_status
  exit 0
fi

log ""
log "${BLUE}╔══════════════════════════════════════╗${NC}"
log "${BLUE}║     BSVibe Production Deploy         ║${NC}"
log "${BLUE}╚══════════════════════════════════════╝${NC}"
log ""

TARGET="${1:-all}"
FAILED=0

for project_def in "${PROJECTS[@]}"; do
  local IFS='|'
  read -r name _ <<< "$project_def"

  if [ "$TARGET" = "all" ] || [ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" = "$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')" ]; then
    deploy_project "$project_def" || ((FAILED++))
  fi
done

if [ $FAILED -eq 0 ]; then
  log "${GREEN}━━━ All deployments successful ━━━${NC}"
else
  log "${RED}━━━ $FAILED deployment(s) failed — check $LOG_FILE ━━━${NC}"
  exit 1
fi
