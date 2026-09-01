#!/usr/bin/env bash
# 가드가 **호출되는가** — 라이브러리가 옳아도 부르지 않으면 아무것도 막지 못한다.
#
# 2026-09-01. 배포 블록이 둘(레거시 PROJECTS 루프 · bsvibe-app 블록)이고, 사고는
# bsvibe-app 쪽에서 났다. 한쪽만 배선하면 다른 쪽은 조용히 같은 사고를 낸다 —
# 미러된 표면은 덜 검사되는 쪽으로 갈라진다.
#
# ⚠️ 라이브 실증(배포 디렉터리에서 브랜치를 파고 폴러를 기다리기)은 그 행위 자체가
# 위험해 막혔다. 그래서 순서를 정적으로 고정한다: **가드 호출이 빌드 명령보다 앞에
# 있고, 거부가 빌드를 막는다.**

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/autodeploy.sh"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT 없음"; exit 1; }

echo "== 라이브러리를 로드한다 =="
grep -q 'lib/deploy_ref_guard.sh' "$SCRIPT" \
  && ok "sources deploy_ref_guard.sh" \
  || bad "sources deploy_ref_guard.sh" "가드가 로드되지 않으면 호출은 command not found 로 조용히 빈 문자열이 된다"

echo "== 배포 경로가 둘 다 가드를 부른다 =="
calls=$(grep -c 'deploy_ref_guard_reason' "$SCRIPT")
[ "$calls" -ge 2 ] \
  && ok "guard called in both deploy blocks ($calls call sites)" \
  || bad "guard called in both deploy blocks" "호출 ${calls}회 — 배포 블록은 둘이다(레거시 · bsvibe-app)"

echo "== 배포 블록 **각각**이 자기 가드를 갖는다 =="
# ⚠️ 처음엔 "빌드 줄보다 앞에 가드 호출이 있는가"로 썼는데, 전선을 끊어보니
# **죽지 않았다**: 레거시 루프의 가드가 어휘적으로 앞에 있어서 bsvibe-app 빌드까지
# 덮어줬다. 개수 단언만 죽었다. 그래서 명제를 블록 단위로 다시 쓴다 —
# 스크립트를 bsvibe-app 블록 경계에서 갈라, **빌드가 있는 쪽엔 반드시 가드가 있다.**
MARK=$(grep -n '^# --- bsvibe-app' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$MARK" ]; then
  bad "found the bsvibe-app block marker" "경계를 못 찾으면 블록별 검사가 성립하지 않는다"
else
  ok "block boundary at line $MARK"
  for half in before after; do
    if [ "$half" = before ]; then
      nb=$(awk -v m="$MARK" 'NR<m' "$SCRIPT" | grep -c 'up -d --build')
      ng=$(awk -v m="$MARK" 'NR<m' "$SCRIPT" | grep -c 'deploy_ref_guard_reason')
    else
      nb=$(awk -v m="$MARK" 'NR>=m' "$SCRIPT" | grep -c 'up -d --build')
      ng=$(awk -v m="$MARK" 'NR>=m' "$SCRIPT" | grep -c 'deploy_ref_guard_reason')
    fi
    if [ "$nb" -gt 0 ] && [ "$ng" -eq 0 ]; then
      bad "$half-marker block guards its builds" "빌드 ${nb}개, 가드 0개 — 이 블록은 무방비다"
    else
      ok "$half-marker block: ${nb} build(s), ${ng} guard(s)"
    fi
  done
fi

echo "== 거부가 실제로 빌드를 막는다 =="
grep -q 'REFUSING TO DEPLOY' "$SCRIPT" \
  && ok "refusal is logged loudly" \
  || bad "refusal is logged loudly" "조용한 스킵은 2026-09-01 처럼 로그만 보면 정상으로 보인다"
# 거부 뒤에는 흐름을 끊는 것이 와야 한다 — continue(레거시) 또는 proceed=false(bsvibe-app)
after=$(grep -A2 'REFUSING TO DEPLOY' "$SCRIPT" | grep -cE 'continue|proceed=false')
[ "$after" -ge 2 ] \
  && ok "each refusal stops the deploy (continue / proceed=false)" \
  || bad "each refusal stops the deploy" "흐름을 끊는 문장이 ${after}곳 — 로그만 찍고 배포하면 가드가 아니다"

echo "== .deployed 에 \$REMOTE 를 적지 않는다 =="
# 사고 때 이 기록이 거짓이라(빌드=789a964, 기록=40d811a) 매 사이클 재배포 루프가 돌았다.
grep -qE 'echo "\$REMOTE" > "\$DEPLOYED_FILE"' "$SCRIPT" \
  && bad ".deployed records what was BUILT" "아직 \$REMOTE 를 적는다 — 빌드한 것과 다를 수 있다" \
  || ok ".deployed records what was BUILT, not the ref it hoped for"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
