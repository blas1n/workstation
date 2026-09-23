#!/usr/bin/env bash
# test_watchdog_vault_notice_is_separate.sh — 금고 점검이 **프로덕션 알람을 오염시키지 않는다.**
#
# 형님 원칙: 사람 대기를 알람으로 만들면 그 알람은 곧 무시되고, 진짜 고장이 났을 때
# 아무도 안 본다. 금고 세션 만료는 `bw login` 한 번이면 끝나는 유지보수다 —
# 🚨 프로덕션 이상과 같은 봉투에 넣으면 안 된다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/watchdog.sh"

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

code=$(grep -vE '^[[:space:]]*#' "$S")   # 주석은 제외 — 오늘 세 번 자기 설명에 걸렸다

echo "== 1. 검사를 실제로 부른다 =="
printf '%s\n' "$code" | grep -q 'vault_session_verdict' && ok "calls the verdict" || bad "calls the verdict" "없음"
printf '%s\n' "$code" | grep -q 'declare -F vault_session_verdict' && ok "pins that the lib loaded" || bad "pins that the lib loaded" "로드 실패가 조용히 통과한다"

echo "== 2. ⭐ breaches 에 넣지 않는다 (알람 오염 금지) =="
# `add "..."` 는 프로덕션 이상 목록에 넣는 함수다. 금고 줄이 거기 들어가면
# 🚨 프로덕션 이상 감지 메시지에 섞인다.
if printf '%s\n' "$code" | grep -nE 'add "' | grep -qi 'vault\|금고'; then
  bad "금고가 breaches 에 들어갔다" "프로덕션 알람이 오염된다"
else ok "vault notice stays out of breaches"; fi

echo "== 3. 별도 메시지에 '장애 아님' 이 명시된다 =="
printf '%s\n' "$code" | grep -q '장애 아님' && ok "메시지가 성격을 밝힌다" || bad "성격 명시" "없음"

echo "== 4. ⭐ 디듀프가 있다 — 2분마다 울리면 그게 곧 무시다 =="
printf '%s\n' "$code" | grep -q 'watchdog.vault.state' && ok "별도 상태 파일" || bad "별도 상태 파일" "프로덕션 디듀프와 섞이면 안 된다"
printf '%s\n' "$code" | grep -qE '7 \* 86400' && ok "주 1회" || bad "주 1회 디듀프" "간격이 없다"

echo "== 5. fresh 면 아무 말도 안 한다 =="
printf '%s\n' "$code" | grep -qE '= aging \]\|.*= stale \]\|.*= unknown \]|aging.*stale.*unknown' && ok "aging/stale/unknown 일 때만" || bad "조건" "fresh 에도 보낼 수 있다"

echo "== 6. bw 가 없어도 죽지 않는다 =="
printf '%s\n' "$code" | grep -q 'command -v bw' && ok "guards on bw presence" || bad "bw 부재 가드" "없는 머신에서 watchdog 이 죽는다"

echo "== 7. 문법 =="
bash -n "$S" 2>/dev/null && ok "bash -n clean" || bad "bash -n" "문법 오류"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
