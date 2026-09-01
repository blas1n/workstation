#!/usr/bin/env bash
# test_deploy_ref_guard.sh — autodeploy 는 origin/main 만 배포해야 한다.
#
# 회귀 2026-09-01. 세션이 배포 대상 디렉터리(``WORK=~/Works/<name>/main``)에서
# 브랜치를 만들어 커밋했다. 폴러는 ``LOCAL=rev-parse HEAD`` 로 **그 브랜치 커밋**을
# 읽고, ``git merge origin/main --ff-only`` 를 돌렸다 — 브랜치가 main 보다 **앞서**
# 있으므로 "Already up to date" 로 **성공**했다 — 그리고 그 워킹트리를 빌드해
# ``GIT_SHA=789a964`` 를 prod 에 박았다. main 에 없는 커밋이다.
#
#   14:42:32 [bsvibe-app] Deploying 40d811a...   ← 로그는 40d811a, 실제는 789a964
#   14:44:42 [bsvibe-app] Deploying 40d811a...
#   … 2분마다 11분간 반복 …
#
# ⇒ PR 이 열려 있고 CI 가 한 번 실패한 코드가 prod 에서 돌았다.
#
# ``--ff-only`` 는 가드가 아니었다 — **방향을 잘못 본다.** 앞서 있는 브랜치에
# origin/main 을 병합하면 언제나 성공한다. 검사해야 할 명제는 병합의 성공 여부가
# 아니라 **"빌드할 HEAD 가 origin/main 인가"** 다.

set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/deploy_ref_guard.sh"
# shellcheck source=/dev/null
source "$LIB"

# ⚠️ 부재가 성공을 흉내낸다. 함수가 없으면 ``r`` 이 비고, "사유 없음 = 안전" 검사가
# **전부 통과**한다 — 실제로 이 파일을 처음 돌렸을 때 케이스 6이 그렇게 거짓 초록이었다.
# 그러니 먼저 존재를 못박는다.
if ! declare -F deploy_ref_guard_reason >/dev/null; then
  echo "FAIL: deploy_ref_guard_reason 이 정의되지 않았다 ($LIB) — 빈 사유는 '안전'이 아니라 '미로드'다"
  exit 1
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

# 원격 역할을 할 bare + 작업 클론
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git config user.email t@t; git config user.name t
echo one > f; git add f; git commit -qm one
git push -q origin HEAD:main 2>/dev/null
git branch -q -M main 2>/dev/null || true
git fetch -q origin main
MAIN=$(git rev-parse HEAD)

echo "== 1. HEAD == origin/main → 안전 =="
r=$(deploy_ref_guard_reason "$TMP/work" "$MAIN")
[ -z "$r" ] && ok "clean main deploys" || bad "clean main deploys" "reason=$r"

echo "== 2. 배포 디렉터리에서 브랜치를 파고 커밋 → 거부 (2026-09-01 그 사고) =="
git checkout -q -b feat/some-work
echo two >> f; git commit -qam two
BRANCH_SHA=$(git rev-parse HEAD)
r=$(deploy_ref_guard_reason "$TMP/work" "$MAIN")
[ -n "$r" ] && ok "branch ahead of main is refused" || bad "branch ahead of main is refused" "빈 사유 — 미머지 코드가 prod 로 나간다"
case "$r" in
  *feat/some-work*) ok "reason names the branch (actionable)" ;;
  *)                bad "reason names the branch" "reason=$r" ;;
esac
case "$r" in
  *"${BRANCH_SHA:0:7}"*) ok "reason names the HEAD it refused" ;;
  *)                     bad "reason names the HEAD it refused" "reason=$r" ;;
esac

echo "== 3. ff-only 병합은 이 상황에서 성공한다 — 그래서 가드가 될 수 없다 =="
if git merge origin/main --ff-only >/dev/null 2>&1; then
  ok "merge --ff-only succeeds on a branch ahead of main (the false guard)"
else
  bad "merge --ff-only succeeds" "전제가 바뀌었다 — 사고 재현이 성립하지 않는다"
fi
r=$(deploy_ref_guard_reason "$TMP/work" "$MAIN")
[ -n "$r" ] && ok "guard still refuses AFTER the merge 'succeeded'" || bad "guard still refuses after merge" "여기가 실제 빌드 직전 지점이다"

echo "== 4. main 으로 돌아오면 다시 안전 =="
git checkout -q main
r=$(deploy_ref_guard_reason "$TMP/work" "$MAIN")
[ -z "$r" ] && ok "back on main deploys" || bad "back on main deploys" "reason=$r"

echo "== 5. detached HEAD (과거 커밋) → 거부 =="
echo three >> f; git commit -qam three; NEWER=$(git rev-parse HEAD)
git push -q origin main 2>/dev/null; git fetch -q origin main
git checkout -q "$MAIN"
r=$(deploy_ref_guard_reason "$TMP/work" "$NEWER")
[ -n "$r" ] && ok "detached HEAD behind origin/main is refused" || bad "detached behind is refused" "빈 사유"

echo "== 6. 추적되지 않는 파일은 배포를 막지 않는다 =="
# ⚠️ 과거에 미커밋 파일이 autodeploy 를 **영구 차단**한 함정이 있었다. $WORK 에는
# .vercel/ · 백업 .env 같은 잔여물이 상시 있으므로, 여기서 막으면 prod 가 벽돌이 된다.
git checkout -q main
git reset -q --hard origin/main
touch .vercel-leftover
r=$(deploy_ref_guard_reason "$TMP/work" "$(git rev-parse origin/main)")
[ -z "$r" ] && ok "untracked leftovers do NOT block the deploy" || bad "untracked must not block" "reason=$r"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
