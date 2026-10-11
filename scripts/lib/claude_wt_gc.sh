#!/usr/bin/env bash
# claude_wt_gc.sh — Remote Control 세션이 남긴 worktree(<project>/wt/claude-*)를 지워도 되는지 판정.
#
# 2026-10-11: hpgg 의 새 세션이 "All 5 slots occupied" 로 전부 실패했다. 서버의 연결
# 세션은 0 이었는데 wt/ 에 claude-bridge-* 가 5개 — 모두 깨끗하고 PR 까지 머지된 것.
# 세션을 지우지 않고 두면 WorktreeRemove 훅이 불리지 않는다. 그래서 claude-rc-ensure.sh 가
# 주기적으로 이 판정을 돌려 정리한다.
#
# 지우는 조건 (전부): 그 worktree 를 cwd 로 쓰는 프로세스가 없다 · 최근 활동이 min_age 이전 ·
# 변경 없음 + origin 에 없는 커밋 없음 (claude-wt-hook.sh 의 wt_keep_reason) ·
# main 보다 앞선 커밋이 있으면 그 PR 이 MERGED/CLOSED. 마지막 조건은 나중에 그 세션으로
# 돌아왔을 때 작업 디렉터리가 사라져 있는 일을 줄이려는 것이다.
#
# 필요: claude-wt-hook.sh 를 먼저 source (wt_keep_reason).

# 사용자 프로세스들의 cwd 를 한 줄씩. 한 번 뽑아 파일로 넘긴다.
claude_wt_gc_cwds() {
  lsof -a -u "$(id -un)" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# PR 상태 (MERGED/CLOSED/OPEN/빈 값). 테스트에서 덮어쓴다.
gc_pr_state() {
  local wt="$1" br repo
  br=$(git -C "$wt" branch --show-current 2>/dev/null)
  repo=$(git -C "$wt" remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##; s#\.git$##')
  [ -z "$br" ] || [ -z "$repo" ] && return 0
  gh pr list -R "$repo" --head "$br" --state all --json state -q '.[0].state // empty' 2>/dev/null
}

# 최근 활동 시각(epoch): worktree 의 git index 와 디렉터리 중 늦은 쪽.
gc_last_activity() {
  local wt="$1" gitdir a b
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)
  a=$(stat -f %m "$gitdir/index" 2>/dev/null || echo 0)
  b=$(stat -f %m "$wt" 2>/dev/null || echo 0)
  [ "$a" -gt "$b" ] && echo "$a" || echo "$b"
}

# gc_skip_reason <worktree> <cwds 파일> [min_age 초, 기본 7200] → 빈 값 = 지워도 됨
gc_skip_reason() {
  local wt="$1" cwds="$2" min_age="${3:-7200}" now last r ahead state
  if grep -qxF "$wt" "$cwds" || grep -qF "$wt/" "$cwds"; then
    echo "세션이 사용 중"; return 0
  fi
  now=$(date +%s); last=$(gc_last_activity "$wt")
  [ $((now - last)) -lt "$min_age" ] && { echo "최근 활동 $(( (now - last) / 60 ))분 전"; return 0; }
  r=$(wt_keep_reason "$wt")
  [ -n "$r" ] && { echo "$r"; return 0; }
  ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
  if [ "$ahead" != 0 ]; then
    state=$(gc_pr_state "$wt")
    case "$state" in
      MERGED|CLOSED) ;;
      *) echo "main 보다 ${ahead}커밋 앞서고 PR 이 ${state:-없음}"; return 0 ;;
    esac
  fi
  return 0
}
