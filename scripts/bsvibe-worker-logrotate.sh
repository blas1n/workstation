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

# 2026-09-23 — 대상을 **plist 에서 유도한다.** 예전엔 이 한 줄이 범위였다:
#   LOG_DIR="${HOME}/Library/Logs"  +  find -name 'bsvibe-worker*.log'
# 그 사이 _infra/logs/autodeploy.log 가 225MB, ollama.log 가 102MB 로 자랐다 —
# launchd 로그 345.5MB 중 **상한을 넘은 둘이 전부 그 범위 밖**이었다.
# 목록을 늘리는 대신 launchd 가 "내가 어디에 쓴다"고 적어 둔 곳에서 센다.
AGENT_DIR="${BSVIBE_LOGROTATE_AGENT_DIR:-${HOME}/Library/LaunchAgents}"
MAX_BYTES="${BSVIBE_LOGROTATE_MAX_BYTES:-52428800}"   # 50 MiB
KEEP="${BSVIBE_LOGROTATE_KEEP:-3}"                    # .1.gz .. .N.gz

. "$(dirname "$0")/lib/logrotate_targets.sh"
declare -F launchd_log_targets >/dev/null || {
  echo "FATAL: lib/logrotate_targets.sh 로드 실패 — 대상 0개로 조용히 성공하면 안 된다"; exit 1; }

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() { echo "$(ts) $*"; }

rotated=0
skipped=0

# NUL-delimited so a space in a path cannot split an argument.
while IFS= read -r log; do
  [ -n "$log" ] || continue
  case "$(rotate_verdict "$log" "$MAX_BYTES")" in
    rotate) : ;;
    skip)    skipped=$((skipped + 1)); continue ;;
    *)       continue ;;   # missing — 데몬이 아직 안 돈 로그다. 에러가 아니다
  esac
  size=$(/usr/bin/stat -f '%z' "$log" 2>/dev/null) || continue

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
done < <(launchd_log_targets "$AGENT_DIR")

# ⭐ 대상 수를 함께 찍는다. 0 이면 "돌릴 게 없었다"가 아니라 **아무것도 안 봤다**이고,
#   그 둘은 `rotated=0` 하나로는 구분되지 않는다 — 5달 동안 그렇게 숨었다.
targets=$(launchd_log_targets "$AGENT_DIR" | grep -c .)
say "done targets=${targets} rotated=${rotated} under_threshold=${skipped} max_bytes=${MAX_BYTES}"
if [ "${targets:-0}" -eq 0 ]; then
  say "ERROR 대상이 0개다 — plist 를 못 읽었거나 AGENT_DIR 이 틀렸다 ($AGENT_DIR)"
  exit 1
fi
