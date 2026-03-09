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
    [ -f "${d}.wt-slot" ] && slot=$(cat "${d}.wt-slot")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "?")
    printf "  %-30s slot=%-3s branch=%s\n" "$name" "$slot" "$branch"
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
[ -f "${WT_PATH}/.wt-slot" ] && SLOT=$(cat "${WT_PATH}/.wt-slot")

echo "Removing worktree: ${PROJECT}/wt/${WT_NAME} (slot: ${SLOT})"

cd "$BARE_DIR"
git worktree remove "$WT_PATH" --force

# Optionally delete the branch
if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
  read -p "Delete branch '${BRANCH}'? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    git branch -D "$BRANCH" 2>/dev/null && echo "  Branch '${BRANCH}' deleted" || echo "  Branch already gone"
  fi
fi

echo "Done. Slot ${SLOT} is now free."
