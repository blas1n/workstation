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

# launchd runs with a minimal PATH that excludes Homebrew — without this, `docker`
# (/opt/homebrew/bin) is not found and the script mis-reports the DB as down.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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

# 5. Off-box copy to Cloudflare R2 (the Mac Mini disk is itself a SPOF).
# Uses the rclone `r2` remote (~/.config/rclone/rclone.conf, mode 0600).
# The R2 API token is IP-restricted to the host's IPv4 egress AND bucket-scoped,
# so we must: (a) force IPv4 — rclone otherwise prefers the endpoint's IPv6,
# whose source IP is NOT allow-listed → 403; (b) --s3-no-check-bucket to skip the
# CreateBucket/HeadBucket/List ops a bucket-scoped token can't perform.
R2_DEST="${BSVIBE_BACKUP_R2_DEST:-r2:bsvibe-backups}"
if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${R2_DEST%%:*}:"; then
  BIND_V4="$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || true)"
  BIND_ARG=""
  [ -n "$BIND_V4" ] && BIND_ARG="--bind $BIND_V4"
  echo "  Off-box → ${R2_DEST}/$(basename "$BACKUP_FILE") (IPv4 ${BIND_V4:-auto}) ..."
  # shellcheck disable=SC2086
  if rclone copyto "$BACKUP_FILE" "${R2_DEST}/$(basename "$BACKUP_FILE")" \
      $BIND_ARG --s3-no-check-bucket --retries 3 --low-level-retries 5 --timeout 180s \
      2>"$BACKUP_DIR/.r2.err"; then
    echo "  Off-box R2 copy OK."
  else
    head -c 400 "$BACKUP_DIR/.r2.err" >&2 || true
    fail "off-box R2 upload failed (local dump is OK)"
  fi
else
  echo "  NOTE: rclone 'r2' remote not configured — off-box copy skipped (dump lives only on this Mac Mini disk, a SPOF)."
fi
# R2 retention: the bucket-scoped token cannot List/Delete, so old objects are
# pruned by an R2 bucket lifecycle rule (set in the Cloudflare dashboard), not here.

# 6. Stamp success (watchdog reads this mtime for a >24h-stale alert).
date -u +%Y-%m-%dT%H:%M:%SZ > "$SUCCESS_MARKER"
echo "=== BSVibe backup OK — $DATE ($SIZE, $KEPT retained) ==="
