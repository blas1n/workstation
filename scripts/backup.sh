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

# Pin the docker context — autodeploy.sh and watchdog.sh guard the same hazard.
# The CLI's current context is global user state, so a `colima start
# <other-profile>` elsewhere repoints these calls at a VM with no bsvibe
# containers. This script then aborts with "postgres container is not running"
# while postgres is healthy, and the day's backup simply does not happen.
# (2026-08-09: the context had drifted to colima-palworld; the 03:00 dump was
# skipped for exactly this reason.)
export DOCKER_CONTEXT=colima

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

# Vault = the founder's knowledge (Markdown, the SoT) + skills, in the backend
# container's appdata volume. pg_dump does NOT cover it, so a disk loss wiped the
# knowledge entirely (readiness audit §Ⅳ, "높음"). Small (~14MB) and irreplaceable
# — backed up here too. runs/products are reconstructable (repos + R2 bundles) and
# huge, so they are deliberately NOT backed up.
BACKEND_CONTAINER="${BSVIBE_BACKEND_CONTAINER:-bsvibe-prod-backend-1}"
VAULT_FILE="$BACKUP_DIR/vault_${DATE}.tgz"
VAULT_MIN_BYTES="${BSVIBE_VAULT_MIN_BYTES:-1024}"

mkdir -p "$BACKUP_DIR"

fail() {
  echo "  FAILURE — $1" >&2
  echo "=== BSVibe backup FAILED — $DATE — $1 ===" >&2
  # Leave the success marker STALE (do not touch it) so freshness monitors fire.
  exit 1
}

# r2_upload FILE — copy one file to the R2 remote (off-box; the Mac Mini disk is
# itself a SPOF). Forces IPv4 (the token is allow-listed to the host's IPv4
# egress; rclone otherwise prefers IPv6 → 403) and --s3-no-check-bucket (the
# bucket-scoped token cannot CreateBucket/HeadBucket/List). Returns non-zero on
# failure so the caller can ``fail``. No-op (returns 0) when rclone's r2 remote
# is not configured — the caller logs a local-only NOTE.
R2_DEST="${BSVIBE_BACKUP_R2_DEST:-r2:bsvibe-backups}"
r2_ready() {
  command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${R2_DEST%%:*}:"
}
r2_upload() {
  _f="$1"
  BIND_V4="$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || true)"
  BIND_ARG=""
  [ -n "$BIND_V4" ] && BIND_ARG="--bind $BIND_V4"
  echo "  Off-box → ${R2_DEST}/$(basename "$_f") (IPv4 ${BIND_V4:-auto}) ..."
  # shellcheck disable=SC2086
  rclone copyto "$_f" "${R2_DEST}/$(basename "$_f")" \
    $BIND_ARG --s3-no-check-bucket --retries 3 --low-level-retries 5 --timeout 180s \
    2>"$BACKUP_DIR/.r2.err"
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
if r2_ready; then
  if r2_upload "$BACKUP_FILE"; then
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

# 5b. Vault + skills backup (the knowledge SoT; pg_dump does not cover it).
echo "  Backing up vault + skills from $BACKEND_CONTAINER ..."
if ! docker inspect -f '{{.State.Running}}' "$BACKEND_CONTAINER" >/dev/null 2>&1; then
  fail "backend container $BACKEND_CONTAINER is not running (vault backup)"
fi
# tar only the irreplaceable trees (vault + skills), NOT runs/products (huge,
# reconstructable). ``|| true`` on tar's exit is NOT used — a tar error must fail.
if ! docker exec "$BACKEND_CONTAINER" tar czf - -C /app/var vault skills 2>"$BACKUP_DIR/.vault.err" > "$VAULT_FILE"; then
  head -c 400 "$BACKUP_DIR/.vault.err" >&2 || true
  rm -f "$VAULT_FILE"
  fail "vault tar pipeline errored"
fi
if ! gzip -t "$VAULT_FILE" 2>/dev/null; then
  rm -f "$VAULT_FILE"
  fail "vault archive failed gzip integrity check"
fi
VBYTES="$(wc -c < "$VAULT_FILE" | tr -d '[:space:]')"
if [ "$VBYTES" -lt "$VAULT_MIN_BYTES" ]; then
  rm -f "$VAULT_FILE"
  fail "vault archive too small (${VBYTES}B < ${VAULT_MIN_BYTES}B) — likely empty/partial"
fi
# Contains real content: at least one .md under vault/.
if ! tar tzf "$VAULT_FILE" 2>/dev/null | grep -q 'vault/.*\.md'; then
  rm -f "$VAULT_FILE"
  fail "vault archive has no vault/*.md files — not a real knowledge tree"
fi
VSIZE="$(du -h "$VAULT_FILE" | cut -f1)"
echo "  Vault OK — $VAULT_FILE ($VSIZE)"
find "$BACKUP_DIR" -name 'vault_*.tgz' -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
if r2_ready; then
  if r2_upload "$VAULT_FILE"; then
    echo "  Vault off-box R2 copy OK."
  else
    head -c 400 "$BACKUP_DIR/.r2.err" >&2 || true
    fail "vault off-box R2 upload failed (local archive is OK)"
  fi
fi

# 6. Stamp success (watchdog reads this mtime for a >24h-stale alert).
date -u +%Y-%m-%dT%H:%M:%SZ > "$SUCCESS_MARKER"
echo "=== BSVibe backup OK — $DATE ($SIZE, $KEPT retained) ==="
