#!/bin/bash
# Auto-deploy: fetch origin/main, pull + rebuild if changed
# Run via launchd every 2 minutes

PROJECTS=(bloasis BSGateway BSNexus bsai BSForge BSage)
LOG=~/Works/_infra/logs/autodeploy.log

for name in "${PROJECTS[@]}"; do
  BARE=~/Works/${name}/.bare
  WORK=~/Works/${name}/main
  COMPOSE=${WORK}/deploy/docker-compose.yml

  [ ! -d "$BARE" ] && continue
  [ ! -f "$COMPOSE" ] && continue

  git -C "$BARE" fetch origin main --quiet 2>/dev/null
  LOCAL=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
  REMOTE=$(git -C "$BARE" rev-parse origin/main 2>/dev/null)

  if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
    echo "$(date) [${name}] Deploying ${REMOTE:0:7}..." >> "$LOG"
    git -C "$WORK" merge origin/main --ff-only 2>> "$LOG"
    docker-compose -f "$COMPOSE" up -d --build >> "$LOG" 2>&1
    echo "$(date) [${name}] Done" >> "$LOG"
  fi
done
