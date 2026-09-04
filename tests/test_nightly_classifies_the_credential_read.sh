#!/usr/bin/env bash
# 러너가 **판정을 부르는가** — 라이브러리가 옳아도 부르지 않으면 아무것도 못 막는다.
# (test_autodeploy_calls_the_ref_guard.sh 와 같은 이유로 있는 파일이다.)
#
# 러너 본체는 sourceable 하지 않다(로드하면 docker 스택을 띄운다). 그래서 명제를
# 정적으로 고정한다: **stderr 를 버리지 않고, 판정을 부르고, unreadable 은 FAIL 이다.**
#
# ⚠️ `2>/dev/null` 하나가 되돌아오면 이 파일이 전부 무의미해진다. 그 문자열의
#    **부재**를 자격증명 읽기 줄에서 직접 센다.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/e2e-live-nightly.sh"
LIB="$ROOT/scripts/lib/keychain_credential.sh"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT 없음"; exit 1; }
[ -f "$LIB" ]    || { echo "FAIL: $LIB 없음 — 러너가 부를 것이 없다"; exit 1; }

echo "== 1. 라이브러리를 로드한다 =="
grep -q 'lib/keychain_credential.sh' "$SCRIPT" \
  && ok "sources keychain_credential.sh" \
  || bad "sources keychain_credential.sh" "로드가 없으면 판정 호출은 command not found 로 빈 문자열이 된다"

echo "== 2. 로드 실패를 스스로 잡는다 =="
grep -q 'declare -F keychain_credential_verdict' "$SCRIPT" \
  && ok "runner pins that the lib actually loaded" \
  || bad "runner pins that the lib actually loaded" "빈 판정은 '괜찮다'가 아니라 '미로드'다"

echo "== 3. 판정을 실제로 부른다 =="
for fn in keychain_credential_verdict keychain_credential_reason; do
  grep -q "$fn \"" "$SCRIPT" && ok "calls $fn" || bad "calls $fn" "호출 지점이 없다"
done

echo "== 4. ⭐ 자격증명 읽기가 stderr 를 버리지 않는다 =="
# 이 결함의 원본이 정확히 이 한 줄이었다.
line=$(grep -n 'security find-generic-password' "$SCRIPT" | head -1)
[ -n "$line" ] || bad "found the credential read" "읽기 줄을 못 찾았다 — 이 검사가 성립하지 않는다"
case "$line" in
  *'2>/dev/null'*) bad "credential read keeps stderr" "$line — 이유가 버려지면 빈 값이 주장이 된다" ;;
  *'2>"$kc_err"'*) ok  "credential read captures stderr" ;;
  *)               bad "credential read captures stderr" "$line" ;;
esac

echo "== 5. rc 를 읽는다 — 빈 문자열이 유일한 신호가 아니다 =="
grep -q 'kc_rc=\$?' "$SCRIPT" \
  && ok "runner reads the exit code" \
  || bad "runner reads the exit code" "빈 값만 보면 44 와 36 이 같아진다"

echo "== 6. unreadable 은 SKIP 이 아니라 FAIL 이다 =="
# 사람 대기(absent)와 머신 고장(unreadable)이 같은 출구로 나가면 알람이 죽는다.
blk=$(awk '/kc_verdict=\$\(keychain_credential_verdict/,/^else$/' "$SCRIPT")
case "$blk" in
  *'"$kc_verdict" = unreadable'*) ok "branches on the unreadable verdict" ;;
  *)                              bad "branches on the unreadable verdict" "분기가 없다" ;;
esac
# unreadable 분기 안에 fail( 이 있고, absent 분기 안에는 없어야 한다.
un=$(printf '%s\n' "$blk" | awk '/= unreadable \]/,/elif/')
ab=$(printf '%s\n' "$blk" | awk '/= absent \]/,/^else$/')
case "$un" in *'fail "'*) ok "unreadable calls fail() (알람 간다)" ;;
              *)          bad "unreadable calls fail()" "머신 고장이 조용히 지나간다" ;; esac
case "$ab" in *'fail "'*) bad "absent must NOT call fail()" "사람 대기가 알람이 되면 알람이 무시된다" ;;
              *)          ok  "absent stays a silent SKIP" ;; esac

echo "== 7. ⭐대조군 — SKIP 문장이 원인을 재지 않고 단언하지 않는다 =="
# 옛 문장은 리터럴이었다: echo "SKIP: 라이브 E2E — Keychain 에 자격증명이 없다."
# 이제는 사유가 판정에서 온다.
if grep -q 'SKIP: 라이브 E2E — Keychain 에 자격증명이 없다' "$SCRIPT"; then
  bad "SKIP text is derived, not asserted" "하드코딩된 원인이 돌아왔다"
else
  ok "SKIP text is derived, not asserted"
fi
grep -q 'SKIP: 라이브 E2E — \$kc_reason' "$SCRIPT" \
  && ok "SKIP prints the measured reason" \
  || bad "SKIP prints the measured reason" "사유가 로그에 안 나가면 다음 사람이 또 추측한다"

echo "== 8. 문법이 성립한다 (절단이 컴파일 오류로 위장하지 않게) =="
bash -n "$SCRIPT" && ok "bash -n clean" || bad "bash -n clean" "구문 오류"
bash -n "$LIB"    && ok "lib bash -n clean" || bad "lib bash -n clean" "구문 오류"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
