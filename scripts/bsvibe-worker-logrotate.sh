#!/usr/bin/env bash
#
# bsvibe-worker-logrotate.sh — size-capped rotation for the launchd worker logs (#970).
#
# WHY THIS EXISTS
#   #993 cut what each log LINE costs (rich console tracebacks -> one JSON line),
#   but nothing caps the FILE. Measured 2026-09-18: 805 MB across three logs.
#
# WHY copytruncate AND NOT mv
#   launchd holds the fd for StandardOutPath open. Renaming the file leaves the
#   daemon writing to the moved inode, so a mv-based rotation only takes effect
#   after a worker restart — which is why #970 recorded this as needing either
#   sudo (/etc/newsyslog.d) or a restart piggybacked on deploys.
#
#   Measured instead of assumed (2026-09-18, throwaway launchd agent): launchd
#   opens the redirect with O_APPEND, so after `: > file` the next write lands
#   at offset 0 with NO NUL padding and NO sparse hole. Verified by od -c.
#
#   ⇒ copytruncate needs NO restart. That matters beyond convenience: a restart
#   would kill an in-flight agentic turn, and those run for many minutes (a
#   measured one was 13m53s). Rotation must never be able to do that.
#
# Schedule via launchd (preferred — survives reboots):
#   ln -s ~/Works/_infra/launchd/com.blas1n.bsvibe-worker-logrotate.plist \
#         ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.blas1n.bsvibe-worker-logrotate.plist
#
# Logs to ~/Works/_infra/logs/bsvibe-worker-logrotate.log.

set -uo pipefail

LOG_DIR="${HOME}/Library/Logs"
MAX_BYTES="${BSVIBE_LOGROTATE_MAX_BYTES:-52428800}"   # 50 MiB
KEEP="${BSVIBE_LOGROTATE_KEEP:-3}"                    # .1.gz .. .N.gz

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() { echo "$(ts) $*"; }

rotated=0
skipped=0

# NUL-delimited so a space in a path cannot split an argument.
while IFS= read -r -d '' log; do
  size=$(stat -f '%z' "$log" 2>/dev/null) || continue
  if [ "$size" -lt "$MAX_BYTES" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  # Age out the generations before claiming .1.
  i="$KEEP"
  while [ "$i" -gt 1 ]; do
    prev=$((i - 1))
    [ -f "${log}.${prev}.gz" ] && mv -f "${log}.${prev}.gz" "${log}.${i}.gz"
    i="$prev"
  done

  # Copy THEN truncate. The copy is a plain read, so the daemon keeps writing
  # to the same fd throughout; at worst a line straddling the boundary is
  # duplicated into the archive, which is far cheaper than dropping it.
  if cp "$log" "${log}.1" 2>/dev/null; then
    : > "$log"
    gzip -f "${log}.1" 2>/dev/null
    say "rotated $(basename "$log") size=${size}"
    rotated=$((rotated + 1))
  else
    say "ERROR could not copy $(basename "$log") — left untouched"
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -name 'bsvibe-worker*.log' -type f -print0)

say "done rotated=${rotated} under_threshold=${skipped} max_bytes=${MAX_BYTES}"
