#!/usr/bin/env bash
#
# BSVibe production watchdog — the "someone is watching" layer for an unattended
# product. Every ~2min it checks the failure modes that were previously SILENT
# (no alerting existed) and pushes a Telegram alert on any breach:
#   1. DB backup freshness   (~/backups/bsvibe/.last-success mtime)
#   2. executor heartbeat    (max(last_heartbeat) in executor_workers)
#   3. critical containers   (backend / worker / postgres Running)
#   4. wedged runs           (running/open far past the lease)
#
# Debounced: re-alerts only when the breach set CHANGES or every ~30min, and
# sends one "recovered" note when all clear. bash 3.2 compatible; PATH-safe for
# launchd (Homebrew docker not on the minimal launchd PATH).
#
# Config: ~/.bsvibe/watchdog.env (mode 600) with TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ENV_FILE="$HOME/.bsvibe/watchdog.env"
STATE_FILE="$HOME/.bsvibe/watchdog.state"
BACKUP_MARKER="$HOME/backups/bsvibe/.last-success"
PG="bsvibe-prod-postgres-1"

# Thresholds (seconds)
BACKUP_STALE_S=$((26 * 3600))     # daily 03:00 backup; alert if >26h old
EXEC_HB_STALE_S=180               # executor should heartbeat well within 120s
RUN_WEDGE_S=$((2 * 3600))         # a run stuck running/open past the 2h lease
REALERT_S=$((30 * 60))            # re-send an unchanged breach at most every 30min

[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE — cannot alert"; exit 1; }
set -a; . "$ENV_FILE"; set +a

now=$(date +%s)
breaches=""

add() { breaches="${breaches}$1\n"; }

_psql() { docker exec "$PG" psql -U bsvibe -d bsvibe -tAc "$1" 2>/dev/null; }

# 1. Backup freshness
if [ -f "$BACKUP_MARKER" ]; then
  age=$(( now - $(stat -f %m "$BACKUP_MARKER") ))
  [ "$age" -gt "$BACKUP_STALE_S" ] && add "🗄️ DB 백업이 $((age/3600))h 동안 갱신 안 됨 (백업 실패 가능)"
else
  add "🗄️ DB 백업 성공 기록 없음 (.last-success 부재)"
fi

# 2 & 3 require docker; if postgres is unreachable that's itself a breach.
if ! docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null | grep -q true; then
  add "🐘 postgres 컨테이너 다운 ($PG)"
else
  # 2. Executor heartbeat (most-recent across all workers)
  hb=$(_psql "select coalesce(round(extract(epoch from now()-max(last_heartbeat))), 999999) from executor_workers")
  hb=${hb:-999999}
  [ "$hb" -gt "$EXEC_HB_STALE_S" ] && add "🤖 라이브 executor 없음 — 최근 heartbeat ${hb}s 전 (work 단계 stall)"

  # 4. Wedged runs
  wedged=$(_psql "select count(*) from execution_runs where status in ('running','open') and updated_at < now() - interval '${RUN_WEDGE_S} seconds'")
  wedged=${wedged:-0}
  [ "$wedged" -gt 0 ] && add "⚙️ run ${wedged}건이 2h+ running/open에 끼임 (wedge 의심)"
fi

# 3. Critical containers up
for c in bsvibe-prod-backend-1 bsvibe-prod-worker-1; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || add "📦 컨테이너 다운: $c"
done

# --- debounce + notify ---
sig=$(printf '%b' "$breaches" | sort | md5 2>/dev/null || printf '%b' "$breaches" | md5sum | cut -d' ' -f1)
last_sig=""; last_ts=0
if [ -f "$STATE_FILE" ]; then last_sig=$(sed -n 1p "$STATE_FILE"); last_ts=$(sed -n 2p "$STATE_FILE"); fi
last_ts=${last_ts:-0}

send() { curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode text="$1" >/dev/null 2>&1; }

if [ -n "$breaches" ]; then
  if [ "$sig" != "$last_sig" ] || [ $(( now - last_ts )) -ge "$REALERT_S" ]; then
    send "$(printf '🚨 BSVibe 프로덕션 이상 감지\n\n%b\n확인 필요.' "$breaches")"
    printf '%s\n%s\n' "$sig" "$now" > "$STATE_FILE"
  fi
else
  # recovered: only if we previously had a non-empty breach signature
  if [ -n "$last_sig" ] && [ "$last_sig" != "$(printf '' | md5 2>/dev/null || printf '' | md5sum | cut -d' ' -f1)" ]; then
    send "✅ BSVibe 프로덕션 정상 복구 — 모든 감시 항목 이상 없음."
  fi
  : > "$STATE_FILE"
fi

# quiet on success (launchd log stays small); print on breach for the log trail
[ -n "$breaches" ] && printf '%s breach:\n%b' "$(date -u +%FT%TZ)" "$breaches" || true
exit 0
