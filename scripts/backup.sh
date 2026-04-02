#!/usr/bin/env bash
#
# BSVibe Daily Database Backup
# Usage: ./backup.sh [backup_dir]
#
# Backs up PostgreSQL databases for all BSVibe projects.
# Retains last 7 days of backups.

set -euo pipefail

BACKUP_DIR="${1:-$HOME/backups/bsvibe}"
RETENTION_DAYS=7
DATE=$(date +%Y-%m-%d_%H%M)

# Project databases and their compose names
declare -A PROJECTS=(
  ["bsgateway"]="deploy/docker-compose.yml"
  ["bsnexus"]="deploy/docker-compose.yml"
  ["bsupervisor"]="deploy/docker-compose.yml"
)

WORKS_DIR="$HOME/Works"

mkdir -p "$BACKUP_DIR"

echo "=== BSVibe Database Backup — $DATE ==="

for project in "${!PROJECTS[@]}"; do
  PROJECT_DIR="$WORKS_DIR/$(echo "$project" | sed 's/bsg/BSG/;s/bsn/BSN/;s/bss/BSs/' | sed 's/BSsupervisor/BSupervisor/;s/BSgateway/BSGateway/;s/BSnexus/BSNexus/')/main"
  COMPOSE_FILE="$PROJECT_DIR/${PROJECTS[$project]}"

  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "  SKIP $project — compose file not found: $COMPOSE_FILE"
    continue
  fi

  BACKUP_FILE="$BACKUP_DIR/${project}_${DATE}.sql.gz"

  echo "  Backing up $project..."

  # Find postgres container name
  PG_CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q postgres 2>/dev/null || true)

  if [ -z "$PG_CONTAINER" ]; then
    echo "    SKIP — postgres container not running"
    continue
  fi

  # Run pg_dump inside the container
  docker exec "$PG_CONTAINER" pg_dump -U "$project" "$project" 2>/dev/null | gzip > "$BACKUP_FILE"

  if [ -s "$BACKUP_FILE" ]; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "    OK — $BACKUP_FILE ($SIZE)"
  else
    echo "    WARN — backup file is empty, removing"
    rm -f "$BACKUP_FILE"
  fi
done

# Cleanup old backups
echo ""
echo "  Cleaning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null
REMAINING=$(find "$BACKUP_DIR" -name "*.sql.gz" | wc -l | tr -d ' ')
echo "  $REMAINING backup files remaining"

echo ""
echo "=== Backup complete ==="
