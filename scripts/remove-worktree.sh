#!/bin/bash
set -euo pipefail

# remove-worktree.sh — Remove a git worktree and free its port slot
#
# Usage:
#   remove-worktree.sh <project> <worktree-name>
#   remove-worktree.sh bloasis feature-new-api
#
# Lists worktrees if no worktree-name given:
#   remove-worktree.sh bloasis

WORKS_DIR=~/Works

PROJECT="${1:-}"
WT_NAME="${2:-}"

[ -z "$PROJECT" ] && echo "Usage: $(basename "$0") <project> [worktree-name]" && exit 1

BARE_DIR="${WORKS_DIR}/${PROJECT}/.bare"
WT_DIR="${WORKS_DIR}/${PROJECT}/wt"

[ ! -d "$BARE_DIR" ] && echo "Error: Bare repo not found at $BARE_DIR" && exit 1

# ─── List mode ───────────────────────────────────────────────────────
if [ -z "$WT_NAME" ]; then
  echo "Worktrees for ${PROJECT}:"
  echo ""

  if [ ! -d "$WT_DIR" ] || [ -z "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
    echo "  (none)"
    exit 0
  fi

  for d in "$WT_DIR"/*/; do
    [ ! -d "$d" ] && continue
    name=$(basename "$d")
    slot="-"
    [ -f "${BARE_DIR}/worktrees/${name}/wt-slot" ] && slot=$(cat "${BARE_DIR}/worktrees/${name}/wt-slot")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "?")
    dc_project=$(echo "${PROJECT}-${name}" | tr '[:upper:]' '[:lower:]')
    dc_count=$(docker ps -a --filter "label=com.docker.compose.project=${dc_project}" --format '.' 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-30s slot=%-3s branch=%-20s containers=%s\n" "$name" "$slot" "$branch" "$dc_count"
  done
  echo ""
  echo "Usage: $(basename "$0") ${PROJECT} <worktree-name>"
  exit 0
fi

# ─── Remove ──────────────────────────────────────────────────────────
WT_PATH="${WT_DIR}/${WT_NAME}"

if [ ! -d "$WT_PATH" ]; then
  echo "Error: Worktree not found at $WT_PATH"
  echo "Run '$(basename "$0") ${PROJECT}' to list worktrees."
  exit 1
fi

BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null || echo "")
SLOT="-"
[ -f "${BARE_DIR}/worktrees/${WT_NAME}/wt-slot" ] && SLOT=$(cat "${BARE_DIR}/worktrees/${WT_NAME}/wt-slot")

echo "Removing worktree: ${PROJECT}/wt/${WT_NAME} (slot: ${SLOT})"

# ─── Devcontainer cleanup ─────────────────────────────────────────
DC_PROJECT=$(echo "${PROJECT}-${WT_NAME}" | tr '[:upper:]' '[:lower:]')
CONTAINERS=$(docker ps -a --filter "label=com.docker.compose.project=${DC_PROJECT}" --format '{{.Names}}' 2>/dev/null || true)

if [ -n "$CONTAINERS" ]; then
  echo "Stopping devcontainer containers..."
  docker ps -a --filter "label=com.docker.compose.project=${DC_PROJECT}" --format '{{.Names}}' | xargs -r docker rm -f
  echo "  Removed $(echo "$CONTAINERS" | wc -l | tr -d ' ') container(s)"
fi

VOLUMES=$(docker volume ls --filter "label=com.docker.compose.project=${DC_PROJECT}" --format '{{.Name}}' 2>/dev/null || true)

if [ -n "$VOLUMES" ]; then
  echo "$VOLUMES" | xargs -r docker volume rm >/dev/null 2>&1 || true
  echo "  Removed $(echo "$VOLUMES" | wc -l | tr -d ' ') volume(s)"
fi

IMAGES=$(docker images --filter "reference=${DC_PROJECT}-*" --format '{{.ID}}' 2>/dev/null | sort -u || true)
if [ -n "$IMAGES" ]; then
  echo "$IMAGES" | xargs -r docker rmi -f >/dev/null 2>&1 || true
  echo "  Removed $(echo "$IMAGES" | wc -l | tr -d ' ') image(s)"
fi

NETWORKS=$(docker network ls --filter "label=com.docker.compose.project=${DC_PROJECT}" --format '{{.Name}}' 2>/dev/null || true)
if [ -n "$NETWORKS" ]; then
  echo "$NETWORKS" | xargs -r docker network rm >/dev/null 2>&1 || true
  echo "  Removed $(echo "$NETWORKS" | wc -l | tr -d ' ') network(s)"
fi

cd "$BARE_DIR"
git worktree remove "$WT_PATH" --force

# Delete the branch (skip main)
if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
  git branch -D "$BRANCH" 2>/dev/null && echo "  Branch '${BRANCH}' deleted" || echo "  Branch already gone"
fi

if command -v colima >/dev/null 2>&1 && colima status 2>&1 | grep -q running; then
  colima ssh -- sudo fstrim -av >/dev/null 2>&1 || true
  echo "  Disk blocks returned to host (fstrim)"
fi

echo "Done. Slot ${SLOT} is now free."
