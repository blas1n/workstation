#!/bin/bash
# Bootstrap: initial docker compose up for all projects with deploy/docker-compose.yml

PROJECTS=(bloasis BSGateway BSNexus bsai BSForge BSage)

for name in "${PROJECTS[@]}"; do
  COMPOSE=~/Works/${name}/main/deploy/docker-compose.yml

  [ ! -f "$COMPOSE" ] && continue

  echo "==> Starting ${name}..."
  docker-compose -f "$COMPOSE" up -d --build
done

echo "==> Done"
