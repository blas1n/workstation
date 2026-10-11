#!/usr/bin/env bash
# test_claude_wt_gc.sh — 주기 정리가 지우면 안 되는 worktree 를 지우지 않아야 한다.
#
# 2026-10-11: 세션을 지우지 않고 두면 WorktreeRemove 훅이 불리지 않아 wt/claude-* 가
# 슬롯 5개를 다 차지했다. 그래서 claude-rc-ensure.sh 가 주기적으로 정리한다 — 그 대신
# 정리는 (1) 쓰는 세션이 있거나 (2) 방금 만들어졌거나 (3) 작업이 안 올라갔거나
# (4) PR 이 아직 열린 worktree 를 **절대** 건드리면 안 된다.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/claude-wt-hook.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/claude_wt_gc.sh"

for f in gc_skip_reason wt_keep_reason gc_last_activity; do
  if ! declare -F "$f" >/dev/null; then
    echo "FAIL: $f 가 정의되지 않았다 — 빈 사유는 '지워도 됨'이 아니라 '미로드'다"
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
git clone -q "$TMP/origin.git" "$TMP/wt" 2>/dev/null
cd "$TMP/wt"
git config user.email t@t; git config user.name t
echo one > f; git add f; git commit -qm one
git push -q origin HEAD:main 2>/dev/null
git fetch -q origin
CWDS="$TMP/cwds"; : > "$CWDS"
WT="$TMP/wt"

echo "== 1. 깨끗 + 푸시됨 + 오래됨 + main 과 같음 → 지운다 =="
r=$(gc_skip_reason "$WT" "$CWDS" 0)
[ -z "$r" ] && ok "disposable" || bad "disposable" "reason=$r"

echo "== 2. 세션 프로세스가 그 안을 cwd 로 쓰면 → 남긴다 =="
echo "$WT/server" > "$CWDS"
r=$(gc_skip_reason "$WT" "$CWDS" 0)
[ -n "$r" ] && ok "in use kept ($r)" || bad "in use kept" "빈 사유 — 쓰는 중인 세션의 디렉터리가 지워진다"
echo "$WT" > "$CWDS"
r=$(gc_skip_reason "$WT" "$CWDS" 0)
[ -n "$r" ] && ok "cwd == worktree kept" || bad "cwd == worktree kept" "빈 사유"
echo "${WT}-other" > "$CWDS"
r=$(gc_skip_reason "$WT" "$CWDS" 0)
[ -z "$r" ] && ok "prefix-only match is not 'in use'" || bad "prefix-only match is not 'in use'" "reason=$r"
: > "$CWDS"

echo "== 3. 방금 만들어진 것 → 남긴다 =="
r=$(gc_skip_reason "$WT" "$CWDS" 7200)
[ -n "$r" ] && ok "recent kept ($r)" || bad "recent kept" "빈 사유 — 세션이 cd 하기 전에 지워질 수 있다"

echo "== 4. 커밋 안 한 변경 → 남긴다 =="
echo two >> f
r=$(gc_skip_reason "$WT" "$CWDS" 0)
[ -n "$r" ] && ok "dirty kept ($r)" || bad "dirty kept" "빈 사유"
git checkout -q -- f

echo "== 5. main 보다 앞서고 푸시됨, PR 열림/없음 → 남긴다 · 머지됨/닫힘 → 지운다 =="
git checkout -q -b claude/x
echo three >> f; git commit -qam three
git push -q origin claude/x 2>/dev/null; git fetch -q origin
for st in OPEN ""; do
  gc_pr_state() { echo "$st"; }
  r=$(gc_skip_reason "$WT" "$CWDS" 0)
  [ -n "$r" ] && ok "PR '${st:-없음}' kept ($r)" || bad "PR '${st:-없음}' kept" "빈 사유 — 돌아올 세션의 작업 디렉터리가 사라진다"
done
for st in MERGED CLOSED; do
  gc_pr_state() { echo "$st"; }
  r=$(gc_skip_reason "$WT" "$CWDS" 0)
  [ -z "$r" ] && ok "PR $st disposable" || bad "PR $st disposable" "reason=$r"
done

[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
