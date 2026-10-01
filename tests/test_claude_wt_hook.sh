#!/usr/bin/env bash
# test_claude_wt_hook.sh — Remote Control 세션이 끝날 때 worktree 정리 훅이 작업을 지우지 않아야 한다.
#
# WorktreeRemove 훅은 세션이 끝날 때마다(폰에서 세션을 지울 때도) 불린다. 그대로
# remove-worktree.sh 를 부르면 worktree 는 --force 로, 브랜치는 -D 로 지워진다 —
# 커밋 안 한 변경과 푸시 안 한 커밋이 함께 사라진다. 훅은 둘 다 없을 때만 정리해야 한다.
# 그리고 WorktreeCreate 는 stdout 에 경로 한 줄만 내야 한다(그 외 출력이 섞이면 세션 cwd 가 깨진다).

set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-wt-hook.sh"
# shellcheck source=/dev/null
source "$HOOK"

for f in wt_keep_reason project_of; do
  if ! declare -F "$f" >/dev/null; then
    echo "FAIL: $f 가 정의되지 않았다 ($HOOK) — 빈 사유는 '지워도 됨'이 아니라 '미로드'다"
    exit 1
  fi
done

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git config user.email t@t; git config user.name t
echo one > f; git add f; git commit -qm one
git push -q origin HEAD:main 2>/dev/null
git fetch -q origin

echo "== 1. 깨끗하고 전부 푸시됨 → 정리해도 된다 =="
r=$(wt_keep_reason "$TMP/work")
[ -z "$r" ] && ok "clean + pushed is disposable" || bad "clean + pushed is disposable" "reason=$r"

echo "== 2. 커밋 안 한 변경 → 남긴다 =="
echo two >> f
r=$(wt_keep_reason "$TMP/work")
[ -n "$r" ] && ok "dirty is kept ($r)" || bad "dirty is kept" "빈 사유 — 변경이 지워진다"
git checkout -q -- f

echo "== 3. 푸시 안 한 커밋 → 남긴다 =="
git checkout -q -b claude/session-x
echo three >> f; git commit -qam three
r=$(wt_keep_reason "$TMP/work")
[ -n "$r" ] && ok "unpushed commit is kept ($r)" || bad "unpushed commit is kept" "빈 사유 — 커밋이 -D 로 지워진다"

echo "== 4. 푸시하면 다시 정리 가능 =="
git push -q origin claude/session-x 2>/dev/null; git fetch -q origin
r=$(wt_keep_reason "$TMP/work")
[ -z "$r" ] && ok "pushed branch is disposable" || bad "pushed branch is disposable" "reason=$r"

echo "== 5. 프로젝트 이름은 ~/Works 바로 아래 디렉터리 =="
WORKS_DIR=/w
[ "$(project_of /w/hpgg)" = hpgg ] && ok "root → hpgg" || bad "root → hpgg" "got '$(project_of /w/hpgg)'"
[ "$(project_of /w/hpgg/wt/a)" = hpgg ] && ok "wt/a → hpgg" || bad "wt/a → hpgg" "got '$(project_of /w/hpgg/wt/a)'"
[ -z "$(project_of /elsewhere/x)" ] && ok "outside → empty" || bad "outside → empty" "got '$(project_of /elsewhere/x)'"

echo "== 6. Remove 를 실제로 돌리면: 변경이 있으면 exit≠0, 디렉터리 그대로 =="
echo four >> f
WORKS_DIR="$TMP" ; mkdir -p "$TMP/proj"
out=$(printf '{"hook_event_name":"WorktreeRemove","cwd":"%s","worktree_path":"%s"}' "$TMP/proj" "$TMP/work" \
  | WORKS_DIR="$TMP" bash "$HOOK" 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -d "$TMP/work" ] && ok "remove refused, dir kept" || bad "remove refused, dir kept" "rc=$rc out=$out"

[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
