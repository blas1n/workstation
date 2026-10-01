#!/usr/bin/env bash
# claude-wt-hook.sh — Claude Code 의 WorktreeCreate / WorktreeRemove 훅.
#
# ``claude remote-control --spawn worktree`` 서버를 프로젝트 루트(~/Works/<project>,
# .bare + main + wt 구조라 git 저장소가 아니다)에서 띄우면, 세션마다 이 훅이 불린다.
# 기본 git worktree 대신 create-worktree.sh 로 위임해서 세션이 <project>/wt/<이름> 에
# 포트 슬롯·.env 까지 갖춘 채 생기게 한다. main/ 은 배포 체크아웃이라 세션이 직접 쓰지 않는다.
#
# 훅 계약 (code.claude.com/docs/en/hooks):
#   stdin  : JSON. Create → worktree_name, cwd / Remove → worktree_path, cwd
#   Create : stdout 에 worktree 절대경로 **한 줄만**. 그래서 하위 스크립트 출력은 전부 stderr 로.
#   Remove : exit 0 이면 정리 완료, 0 이 아니면 디렉터리가 남고 경고만 뜬다.
#
# ⚠️ remove-worktree.sh 는 worktree 를 --force 로 지우고 브랜치까지 -D 로 지운다.
# 세션이 끝날 때마다 그걸 그대로 부르면 푸시 안 한 작업이 사라진다. 그래서 Remove 는
# "변경 없음 + origin 에 없는 커밋 없음" 일 때만 정리하고, 아니면 남겨 둔다(exit 1).
#
# 설치: ~/Works/<project>/.claude/settings.json 의 hooks 에서 이 파일을 가리킨다
#       (templates/claude-rc-project-settings.json 참고).

WORKS_DIR="${WORKS_DIR:-$HOME/Works}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cwd(=프로젝트 루트 또는 그 아래)에서 프로젝트 이름을 뽑는다. ~/Works 밖이면 빈 값.
project_of() {
  local rel="${1#"$WORKS_DIR"/}"
  [ "$rel" = "$1" ] && return 0
  printf '%s\n' "${rel%%/*}"
}

# 지워도 잃을 게 없는 worktree 인가. 아니면 그 이유를 stdout 에 낸다(빈 값 = 지워도 됨).
wt_keep_reason() {
  local wt="$1" dirty unpushed
  [ -d "$wt" ] || return 0
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" != 0 ] && { echo "커밋 안 된 변경 ${dirty}개"; return 0; }
  unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo "?")
  [ "$unpushed" != 0 ] && { echo "origin 에 없는 커밋 ${unpushed}개"; return 0; }
  return 0
}

main() {
  set -euo pipefail
  local input event cwd project
  input=$(cat)
  event=$(jq -r '.hook_event_name // empty' <<<"$input")
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  project=$(project_of "$cwd")
  [ -z "$project" ] && { echo "claude-wt-hook: ~/Works 밖이다 (cwd=$cwd)" >&2; exit 1; }

  case "$event" in
    WorktreeCreate)
      local name branch wt_name
      name=$(jq -r '.worktree_name // empty' <<<"$input")
      [ -z "$name" ] && { echo "claude-wt-hook: worktree_name 이 없다" >&2; exit 1; }
      branch="claude/${name}"
      # create-worktree.sh 와 같은 규칙으로 디렉터리 이름을 만든다.
      wt_name=$(echo "$branch" | sed 's|/|-|g; s|[^a-zA-Z0-9._-]|-|g')
      "$SCRIPTS_DIR/create-worktree.sh" "$project" "$branch" >&2
      printf '%s\n' "$WORKS_DIR/$project/wt/$wt_name"
      ;;
    WorktreeRemove)
      local wt reason
      wt=$(jq -r '.worktree_path // empty' <<<"$input")
      [ -z "$wt" ] && exit 0
      reason=$(wt_keep_reason "$wt")
      if [ -n "$reason" ]; then
        echo "claude-wt-hook: $wt 를 남긴다 — $reason. 정리는 remove-worktree.sh $project $(basename "$wt")" >&2
        exit 1
      fi
      "$SCRIPTS_DIR/remove-worktree.sh" "$project" "$(basename "$wt")" >&2
      ;;
    *)
      echo "claude-wt-hook: 모르는 이벤트 '$event'" >&2
      exit 1
      ;;
  esac
}

# 테스트가 source 해서 함수만 쓸 수 있게, 직접 실행될 때만 main 을 돈다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
