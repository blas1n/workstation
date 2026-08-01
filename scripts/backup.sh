#!/usr/bin/env bash
#
# BSVibe production database backup.
#
# Dumps the LIVE `bsvibe` database (container bsvibe-prod-postgres-1), verifies
# the dump is intact + non-trivial, retains N days, and FAILS LOUDLY (exit != 0
# + a stale success-marker) so a watchdog can alert. Written for macOS system
# bash 3.2.57 — NO associative arrays / mapfile / other bash-4 features.
#
# Prior version aborted on every run (`declare -A` under bash 3.2) AND targeted
# only decommissioned DBs (bsgateway/bsnexus/bsupervisor) — the live bsvibe DB
# had NEVER been dumped. This is the fix.
#
# Usage: ./backup.sh [backup_dir]
# launchd: com.blas1n.backup runs this daily; StandardOut/Err → _infra/logs/backup.log

set -euo pipefail

BACKUP_DIR="${1:-$HOME/backups/bsvibe}"
RETENTION_DAYS="${BSVIBE_BACKUP_RETENTION_DAYS:-14}"
# Minimum plausible gzipped dump size (bytes). The real dump is ~18MB gzipped;
# anything under 1MB means pg_dump produced garbage/empty and we must fail loud.
MIN_BYTES="${BSVIBE_BACKUP_MIN_BYTES:-1048576}"

PG_CONTAINER="bsvibe-prod-postgres-1"
PG_USER="bsvibe"      # DB owner — dumps everything (app connects as bsvibe_app)
PG_DB="bsvibe"

DATE="$(date +%Y-%m-%d_%H%M)"
BACKUP_FILE="$BACKUP_DIR/bsvibe_${DATE}.sql.gz"
SUCCESS_MARKER="$BACKUP_DIR/.last-success"   # a watchdog checks this file's mtime

mkdir -p "$BACKUP_DIR"

fail() {
  echo "  FAILURE — $1" >&2
  echo "=== BSVibe backup FAILED — $DATE — $1 ===" >&2
  # Leave the success marker STALE (do not touch it) so freshness monitors fire.
  exit 1
}

echo "=== BSVibe database backup — $DATE ==="

# 1. Container must be running.
if ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" >/dev/null 2>&1; then
  fail "postgres container $PG_CONTAINER is not running"
fi

# 2. Dump → gzip. pipefail makes a pg_dump error fail the pipeline (not just gzip).
echo "  Dumping $PG_DB from $PG_CONTAINER ..."
if ! docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" 2>"$BACKUP_DIR/.pg_dump.err" | gzip > "$BACKUP_FILE"; then
  head -c 500 "$BACKUP_DIR/.pg_dump.err" >&2 || true
  rm -f "$BACKUP_FILE"
  fail "pg_dump/gzip pipeline errored"
fi

# 3. Verify: gzip integrity + non-trivial size + contains real schema.
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
  rm -f "$BACKUP_FILE"
  fail "dump failed gzip integrity check"
fi
BYTES="$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')"
if [ "$BYTES" -lt "$MIN_BYTES" ]; then
  rm -f "$BACKUP_FILE"
  fail "dump too small (${BYTES}B < ${MIN_BYTES}B) — likely empty/partial"
fi
# Use grep -c (reads the whole stream) not grep -q (early-exits → SIGPIPEs gzip
# → false failure under `set -o pipefail`).
TABLE_COUNT="$(gzip -dc "$BACKUP_FILE" | grep -c 'CREATE TABLE' || echo 0)"
if [ "$TABLE_COUNT" -lt 1 ]; then
  rm -f "$BACKUP_FILE"
  fail "dump has no CREATE TABLE statements — not a real schema"
fi
echo "  Verified: $TABLE_COUNT CREATE TABLE statements."

SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"
echo "  OK — $BACKUP_FILE ($SIZE)"

# 4. Retention: delete dumps older than N days (keep the marker + err file).
find "$BACKUP_DIR" -name 'bsvibe_*.sql.gz' -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
KEPT="$(find "$BACKUP_DIR" -name 'bsvibe_*.sql.gz' -type f | wc -l | tr -d '[:space:]')"
echo "  Retained $KEPT dump(s) (last ${RETENTION_DAYS} days)."

# 5. Optional off-box copy (the Mac Mini disk is itself a SPOF). Set
# BSVIBE_BACKUP_OFFBOX_DEST=user@host:/path or an rsync target to enable.
if [ -n "${BSVIBE_BACKUP_OFFBOX_DEST:-}" ]; then
  echo "  Off-box copy → $BSVIBE_BACKUP_OFFBOX_DEST ..."
  if ! rsync -a "$BACKUP_FILE" "$BSVIBE_BACKUP_OFFBOX_DEST/" 2>&1; then
    fail "off-box rsync to $BSVIBE_BACKUP_OFFBOX_DEST failed (local dump is OK)"
  fi
  echo "  Off-box copy OK."
else
  echo "  NOTE: no off-box destination set (BSVIBE_BACKUP_OFFBOX_DEST) — dump lives only on this Mac Mini disk (a SPOF). Set it to protect against disk failure."
fi

# 6. Stamp success (watchdog reads this mtime for a >24h-stale alert).
date -u +%Y-%m-%dT%H:%M:%SZ > "$SUCCESS_MARKER"
echo "=== BSVibe backup OK — $DATE ($SIZE, $KEPT retained) ==="
