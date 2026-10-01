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
