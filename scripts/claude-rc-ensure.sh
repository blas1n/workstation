#!/usr/bin/env bash
# claude-rc-ensure.sh — Claude Remote Control 서버들을 tmux 세션 rc-<이름> 으로 살려 둔다.
#
# 폰/claude.ai 에서 세션을 그때그때 새로 여는 상시 서버다. 미리 세션 여러 개를 띄워 두던
# 방식은 맥미니 재부팅(2026-10-01) 한 번에 전부 끊겼고 손으로 다시 띄워야 했다.
#
# launchd(com.blas1n.claude-rc-ensure)가 부팅 시 + 60초마다 실행한다. 살아 있으면 no-op.
# launchd 가 claude 를 직접 띄우지 않는 이유: remote-control 은 표준입출력이 터미널이
# 아니면 신뢰 확인을 못 해 종료한다. tmux 가 TTY 를 준다 — 그리고 신뢰가 풀려도
# ``tmux attach -t rc-<이름>`` 으로 들어가 바로 답할 수 있다.
#
# 프로젝트 서버는 프로젝트 루트(.bare + main + wt)에서 --spawn worktree 로 돈다.
# 세션마다 claude-wt-hook.sh → create-worktree.sh 로 wt/ 에 worktree 가 생긴다.
# --no-create-session-in-dir: 루트에 미리 세션을 만들지 않는다(모든 작업은 wt/ 에서).
# --capacity 5: create-worktree.sh 의 포트 슬롯 수(MAX_SLOTS=5)와 맞춘다.

set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

W="$HOME/Works"
WT_OPTS="--spawn worktree --no-create-session-in-dir --capacity 5"

# 이름|디렉터리|옵션
SERVERS=(
  "works|$W|--spawn same-dir"
  "bsvibe|$W/bsvibe-app|$WT_OPTS"
  "hpgg|$W/hpgg|$WT_OPTS"
  "bloasis|$W/bloasis|$WT_OPTS"
  "bstalk3r|$W/BStalk3r|$WT_OPTS"
  "bstockreport|$W/BStockReport|$WT_OPTS"
  "bsplay|$W/BSPlay|$WT_OPTS"
  "infra|$W/_infra|--spawn same-dir"
)

for s in "${SERVERS[@]}"; do
  IFS='|' read -r name dir opts <<<"$s"
  sess="rc-$name"
  tmux has-session -t "=$sess" 2>/dev/null && continue
  if [ ! -d "$dir" ]; then
    echo "$(date '+%F %T') [$name] 디렉터리 없음: $dir"
    continue
  fi
  echo "$(date '+%F %T') [$name] 시작 ($dir)"
  # 서버가 죽으면 세션도 닫히고, 다음 주기(60초)에 다시 뜬다.
  # shellcheck disable=SC2086
  tmux new-session -d -s "$sess" -c "$dir" \
    "claude remote-control --name $name --permission-mode auto $opts; sleep 5"
done

# ─── 남은 worktree 정리 (10분마다) ───────────────────────────────────
# 판정은 lib/claude_wt_gc.sh. 지우는 건 claude-* 만 — 사람이 만든 worktree 는 건드리지 않는다.
INFRA="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$INFRA/logs"
GC_STAMP="$INFRA/logs/.claude-wt-gc.last"
if [ $(( $(date +%s) - $(cat "$GC_STAMP" 2>/dev/null || echo 0) )) -ge 600 ]; then
  date +%s > "$GC_STAMP"
  # shellcheck source=/dev/null
  . "$INFRA/scripts/claude-wt-hook.sh"
  # shellcheck source=/dev/null
  . "$INFRA/scripts/lib/claude_wt_gc.sh"
  cwds=$(mktemp)
  claude_wt_gc_cwds > "$cwds"
  for wt in "$W"/*/wt/claude-*/; do
    wt="${wt%/}"
    [ -d "$wt" ] || continue
    project=$(basename "$(dirname "$(dirname "$wt")")")
    [ -n "$(gc_skip_reason "$wt" "$cwds")" ] && continue
    if "$INFRA/scripts/remove-worktree.sh" "$project" "$(basename "$wt")" >/dev/null 2>&1; then
      echo "$(date '+%F %T') [gc] $project/$(basename "$wt") 정리"
    else
      echo "$(date '+%F %T') [gc] $project/$(basename "$wt") 정리 실패"
    fi
  done
  rm -f "$cwds"
fi

# ─── 반복 재시작 알림 ────────────────────────────────────────────────
# 2026-10-11: 로그인이 만료되자 서버가 뜨자마자 죽고 60초마다 다시 떴다 — 폰에서
# "OAuth session expired" 를 보기 전까지 아무도 몰랐다. 정상이면 10분간 "시작" 이
# 거의 없다. 서버당 두 번 넘게 다시 떴고 **지금도**(최근 2분) 뜨고 있으면 알린다
# (한 시간에 한 번). 지금 조건이 없으면 이미 풀린 루프를 10분 뒤까지 알린다.
LOG="${CLAUDE_RC_LOG:-$INFRA/logs/claude-rc-ensure.log}"
ALERT_STAMP="$INFRA/logs/.claude-rc-alert.last"
since=$(date -v-10M '+%F %T')
starts=$(awk -v s="$since" 'substr($0,1,19) >= s && /\] 시작 \(/' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
now_starts=$(awk -v s="$(date -v-2M '+%F %T')" 'substr($0,1,19) >= s && /\] 시작 \(/' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
if [ "${starts:-0}" -gt $(( ${#SERVERS[@]} * 2 )) ] && [ "${now_starts:-0}" -gt 0 ] &&
   [ $(( $(date +%s) - $(cat "$ALERT_STAMP" 2>/dev/null || echo 0) )) -ge 3600 ]; then
  date +%s > "$ALERT_STAMP"
  echo "$(date '+%F %T') [alert] 10분간 재시작 ${starts}회"
  ENV_FILE="${WATCHDOG_ENV:-$HOME/.bsvibe/watchdog.env}"
  # shellcheck source=/dev/null
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode text="⚠️ 맥미니 Claude Remote Control 서버가 10분간 ${starts}회 재시작 — 로그인 만료일 수 있다.
ssh bsserver → security unlock-keychain ~/Library/Keychains/login.keychain-db → claude auth login
(상태: tmux attach -t rc-works)" >/dev/null 2>&1
  fi
fi
