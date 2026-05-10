#!/bin/bash
# Auto-deploy: fetch origin/main, pull + rebuild if changed
# Run via launchd every 2 minutes

export PATH="/opt/homebrew/bin:$PATH"

PROJECTS=(bloasis BSGateway BSNexus bsai BSForge BSage BSupervisor)
# Projects with a public demo stack (deploy/docker-compose.demo.yml + .env.demo)
DEMO_PROJECTS=(BSGateway BSNexus BSage BSupervisor)
LOG_DIR=~/Works/_infra/logs
LOG=$LOG_DIR/autodeploy.log
# Per-project state files recording the commit hash of the last
# *successfully deployed* image. Compared against LOCAL — a mismatch
# means the build artifact is stale even when the source tree matches
# origin/main, which is the failure mode that kept BSNexus's PR #53
# from going live for ~30 minutes after merge (2026-05-05). Without
# this check, ``LOCAL == REMOTE`` is taken as "all good" and rebuild
# is skipped, even when the running container is older than LOCAL.
mkdir -p "$LOG_DIR"

for name in "${PROJECTS[@]}"; do
  BARE=~/Works/${name}/.bare
  WORK=~/Works/${name}/main
  COMPOSE=${WORK}/deploy/docker-compose.yml
  DEMO_COMPOSE=${WORK}/deploy/docker-compose.demo.yml
  DEMO_ENV=${WORK}/deploy/.env.demo
  DEPLOYED_FILE=$LOG_DIR/${name}.deployed

  [ ! -d "$BARE" ] && continue

  # fetch refspec이 없으면 추가 (bare repo에서 origin/main ref 생성에 필요)
  if ! git -C "$BARE" config --get remote.origin.fetch &>/dev/null; then
    git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  fi

  git -C "$BARE" fetch origin main --quiet 2>/dev/null
  LOCAL=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
  REMOTE=$(git -C "$BARE" rev-parse origin/main 2>/dev/null)
  DEPLOYED=$(cat "$DEPLOYED_FILE" 2>/dev/null)

  [ -z "$REMOTE" ] && continue

  # Trigger rebuild when EITHER:
  #   * source tree diverged from origin/main (normal: PR was merged)
  #   * source tree matches origin/main BUT the recorded deployed
  #     commit doesn't (the container is stale because someone reset
  #     the worktree, or this is the very first deploy after the
  #     state-file was introduced)
  needs_merge=false
  needs_build=false
  [ "$LOCAL" != "$REMOTE" ] && needs_merge=true
  [ "$DEPLOYED" != "$REMOTE" ] && needs_build=true

  if [ "$needs_merge" = false ] && [ "$needs_build" = false ]; then
    continue
  fi

  if [ "$needs_merge" = true ]; then
    echo "$(date) [${name}] Deploying ${REMOTE:0:7}..." >> "$LOG"
    if ! git -C "$WORK" merge origin/main --ff-only 2>> "$LOG"; then
      echo "$(date) [${name}] Merge failed, skipping rebuild" >> "$LOG"
      continue
    fi
  else
    echo "$(date) [${name}] Stale image (deployed=${DEPLOYED:0:7} vs source=${REMOTE:0:7}) — rebuilding" >> "$LOG"
  fi

  if [ -f "$COMPOSE" ]; then
    PROJECT_NAME=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if ! docker-compose -p "$PROJECT_NAME" -f "$COMPOSE" up -d --build >> "$LOG" 2>&1; then
      echo "$(date) [${name}] Prod build failed!" >> "$LOG"
      continue
    fi
  fi

  # Rebuild demo stack alongside prod (only if demo files exist for this project)
  is_demo_project=false
  for dp in "${DEMO_PROJECTS[@]}"; do
    [ "$dp" = "$name" ] && is_demo_project=true && break
  done
  if [ "$is_demo_project" = true ] && [ -f "$DEMO_COMPOSE" ] && [ -f "$DEMO_ENV" ]; then
    DEMO_PROJECT_NAME="$(echo "$name" | tr '[:upper:]' '[:lower:]')-demo"
    if ! docker-compose -p "$DEMO_PROJECT_NAME" -f "$DEMO_COMPOSE" --env-file "$DEMO_ENV" up -d --build >> "$LOG" 2>&1; then
      echo "$(date) [${name}] Demo build failed (non-fatal)!" >> "$LOG"
      # Demo failure is non-fatal — prod kept running
    fi
  fi

  # Record the commit we just deployed so the next loop knows the
  # container matches LOCAL even when LOCAL == REMOTE.
  echo "$REMOTE" > "$DEPLOYED_FILE"
  echo "$(date) [${name}] Done" >> "$LOG"
done
