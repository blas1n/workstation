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
# Disk — this Mac Mini runs BOTH prod AND dev; a full disk not only stops prod
# but leaves no room to even fix it (unrecoverable brick). Alert EARLY.
# NOTE: check $HOME (the APFS DATA volume where docker/backups/Works live), NOT
# "/" — on macOS "/" is the tiny read-only System volume and lies about capacity.
DISK_VOL="$HOME"
DISK_FREE_WARN_GB="${BSVIBE_DISK_FREE_WARN_GB:-40}"  # absolute free GB → warn
DISK_FREE_CRIT_GB="${BSVIBE_DISK_FREE_CRIT_GB:-20}"  # absolute free GB → critical
RUNS_DIR_WARN_GB="${BSVIBE_RUNS_DIR_WARN_GB:-30}"    # /app/var/runs scratch growth
PRODUCTS_DIR_WARN_GB="${BSVIBE_PRODUCTS_DIR_WARN_GB:-20}"  # /app/var/products (should stay bounded to ACTIVE products)

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

# 5. Host disk (the dev+prod machine). Alert on ABSOLUTE free space on the DATA
# volume — a full disk can't even be fixed. 1K blocks → GB.
DISK_FREE_KB=$(df -Pk "$DISK_VOL" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$DISK_FREE_KB" ]; then
  DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
  if [ "$DISK_FREE_GB" -le "$DISK_FREE_CRIT_GB" ]; then
    add "💽 디스크 여유 ${DISK_FREE_GB}GB만 남음 — 🔴위험, 즉시 정리 (풀 시 prod정지+복구불능 브릭)"
  elif [ "$DISK_FREE_GB" -le "$DISK_FREE_WARN_GB" ]; then
    add "💽 디스크 여유 ${DISK_FREE_GB}GB — 정리 권장 (dev+prod 겸용 머신)"
  fi
fi

# 6. Run-scratch growth — /app/var/runs (per-run clones/worktrees) should be
# ephemeral; unbounded growth means the terminal-cleanup isn't reclaiming it.
if docker inspect -f '{{.State.Running}}' bsvibe-prod-backend-1 2>/dev/null | grep -q true; then
  runs_kb=$(docker exec bsvibe-prod-backend-1 sh -c "du -sk /app/var/runs 2>/dev/null | cut -f1" 2>/dev/null)
  runs_kb=${runs_kb:-0}
  runs_gb=$(( runs_kb / 1024 / 1024 ))
  [ "$runs_gb" -ge "$RUNS_DIR_WARN_GB" ] && add "🧹 run 작업공간 /app/var/runs = ${runs_gb}GB — terminal 정리가 안 되고 쌓이는 중"
fi

# 7. Product durability — a product whose repo is on disk but whose newest
# state never reached the bundle store is NOT durable, and (unlike a missing
# backup) nothing else would ever surface it. Two signals:
#   a) an unresolved publish conflict → a pending merge_conflict_review Decision
#   b) var/products growing → repos are not being reclaimed (publishes failing)
if docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null | grep -q true; then
  conflicts=$(_psql "select count(*) from decisions where status='pending' and decision='merge_conflict_review' and payload->>'reason'='product_bundle_publish_conflict'")
  conflicts=${conflicts:-0}
  [ "$conflicts" -gt 0 ] && add "📦 제품 ${conflicts}건이 원격 사본과 충돌해 발행 못 함 — 해결 전까지 백업 안 됨 (/brief 에서 확인)"
fi
if docker inspect -f '{{.State.Running}}' bsvibe-prod-backend-1 2>/dev/null | grep -q true; then
  prod_kb=$(docker exec bsvibe-prod-backend-1 sh -c "du -sk /app/var/products 2>/dev/null | cut -f1" 2>/dev/null)
  prod_kb=${prod_kb:-0}
  prod_gb=$(( prod_kb / 1024 / 1024 ))
  [ "$prod_gb" -ge "$PRODUCTS_DIR_WARN_GB" ] && add "📦 제품 저장소 /app/var/products = ${prod_gb}GB — 유휴 제품 회수가 안 되는 중(발행 실패 의심)"
fi

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
