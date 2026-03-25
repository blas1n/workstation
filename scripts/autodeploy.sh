#!/bin/bash
# Auto-deploy: fetch origin/main, pull + rebuild if changed
# Run via launchd every 2 minutes

export PATH="/opt/homebrew/bin:$PATH"

PROJECTS=(bloasis BSGateway BSNexus bsai BSForge BSage)
LOG=~/Works/_infra/logs/autodeploy.log

for name in "${PROJECTS[@]}"; do
  BARE=~/Works/${name}/.bare
  WORK=~/Works/${name}/main
  COMPOSE=${WORK}/deploy/docker-compose.yml

  [ ! -d "$BARE" ] && continue

  # fetch refspec이 없으면 추가 (bare repo에서 origin/main ref 생성에 필요)
  if ! git -C "$BARE" config --get remote.origin.fetch &>/dev/null; then
    git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  fi

  git -C "$BARE" fetch origin main --quiet 2>/dev/null
  LOCAL=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
  REMOTE=$(git -C "$BARE" rev-parse origin/main 2>/dev/null)

  if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
    echo "$(date) [${name}] Deploying ${REMOTE:0:7}..." >> "$LOG"
    if git -C "$WORK" merge origin/main --ff-only 2>> "$LOG"; then
      if [ -f "$COMPOSE" ]; then
        if ! docker-compose -f "$COMPOSE" up -d --build >> "$LOG" 2>&1; then
          echo "$(date) [${name}] Build failed!" >> "$LOG"
          continue
        fi
      fi
      echo "$(date) [${name}] Done" >> "$LOG"
    else
      echo "$(date) [${name}] Merge failed, skipping rebuild" >> "$LOG"
    fi
  fi
done
