#!/usr/bin/env bash
# test_keychain_credential_verdict.sh — 읽기 실패의 **이유**를 잃지 않는다.
#
# 2026-09-04. 야간 러너의 자격증명 읽기는 이랬다:
#
#   password=$(security find-generic-password ... -w 2>/dev/null)
#   if [ -z "$password" ]; then echo "SKIP: ... Keychain 에 자격증명이 없다."
#
# `2>/dev/null` 이 **이유를 버리고**, 빈 문자열이 그대로 **주장**이 된다. 서로 다른
# 두 세계가 같은 문장 하나로 접힌다:
#
#   rc=44  errSecItemNotFound            → 진짜 부재. 사람을 기다린다. SKIP 이 옳다.
#   rc=36  errSecInteractionNotAllowed   → **잠긴 keychain.** 자격증명이 거기 있는데도
#                                          못 읽는 것일 수 있다. 이 머신의 고장이다.
#
# 실측한 값이다(2026-09-04, 이 머신):
#   security find-generic-password -s <없는것> -w   → rc=44
#   security add-generic-password  ... (login kc)  → rc=36  "User interaction is not allowed."
#
# ⭐ 왜 지금 고치나 — 오늘의 호출은 44 를 낸다. 즉 지금 로그의 문장은 **우연히 참**이다.
#    36 이 나오는 자리는 형님이 자격증명을 넣는 **바로 그 다음**이다. 그때 러너는
#    *"자격증명이 없다"* 고 말하고, 형님은 방금 넣은 것을 의심하게 된다.
#    실제로 세 세션이 keychain 실패의 원인을 *"에이전트라서 / OS 경계라서"* 로 적었고
#    전부 틀렸다 — 잠긴 login keychain 이었다. **이 로그가 원인을 재고 있었다면
#    세 세션을 안 썼다.**
#
# 판정은 순수 함수로 뺀다. 러너 본체는 docker 스택과 70~90초 E2E 를 통과해야만
# 이 줄에 닿으므로, 판정을 거기 두면 영원히 테스트되지 않는다.

set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/keychain_credential.sh"
# shellcheck source=/dev/null
[ -f "$LIB" ] && source "$LIB"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

# ⚠️ 부재가 성공을 흉내낸다 — 함수가 없으면 `$(...)` 가 빈 문자열이 되고
# "unreadable 이 아니다" 류의 검사가 조용히 통과한다. 먼저 존재를 못박는다.
missing=0
for fn in keychain_credential_verdict keychain_credential_reason; do
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn 이 정의되지 않았다 ($LIB)"; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "빈 판정은 '괜찮다'가 아니라 '미로드'다"; exit 1; }

INTERACTION_ERR='security: SecKeychainItemCreateFromContent (<default>): User interaction is not allowed.'
NOTFOUND_ERR='security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.'

echo "== 1. rc=0 + 비밀 있음 → ok =="
v=$(keychain_credential_verdict 0 1)
[ "$v" = ok ] && ok "read succeeded" || bad "read succeeded" "verdict=$v"

echo "== 2. rc=44 (errSecItemNotFound) → absent — 사람을 기다린다 =="
v=$(keychain_credential_verdict 44 0)
[ "$v" = absent ] && ok "not-found is absent" || bad "not-found is absent" "verdict=$v"

echo "== 3. rc=36 (errSecInteractionNotAllowed) → unreadable — 이 머신의 고장 =="
# 이 세션의 결함이 정확히 여기다: 36 이 absent 로 접히면 잠긴 keychain 이
# "자격증명이 없다" 로 보고되고, 사람은 이미 한 일을 다시 한다.
v=$(keychain_credential_verdict 36 0)
[ "$v" = unreadable ] && ok "locked keychain is NOT absent" \
  || bad "locked keychain is NOT absent" "verdict=$v — 잠긴 keychain 을 부재로 접었다"

echo "== 4. rc=0 인데 비밀이 비었다 → unreadable (rc 0 은 비밀의 존재가 아니다) =="
v=$(keychain_credential_verdict 0 0)
[ "$v" = unreadable ] && ok "empty secret with rc=0 is a fault" \
  || bad "empty secret with rc=0 is a fault" "verdict=$v"

echo "== 5. 모르는 rc 는 알람 쪽으로 떨어진다 — absent 로 침묵하지 않는다 =="
# 미래의 macOS 가 새 코드를 내면 기본값이 '조용한 SKIP' 이어선 안 된다.
for rc in 1 25 51 25308; do
  v=$(keychain_credential_verdict "$rc" 0)
  [ "$v" = unreadable ] && ok "rc=$rc → unreadable" \
    || bad "rc=$rc → unreadable" "verdict=$v — 모르는 실패가 사람 대기로 접혔다"
done

echo "== 6. 사유가 원인을 지목한다 (36) =="
r=$(keychain_credential_reason 36 "$INTERACTION_ERR")
case "$r" in
  *잠겨*|*잠긴*|*unlock*) ok "reason names the lock" ;;
  *)                      bad "reason names the lock" "reason=$r" ;;
esac
case "$r" in
  *"User interaction is not allowed"*) ok "reason carries the raw stderr (진단 가능)" ;;
  *)                                   bad "reason carries the raw stderr" "reason=$r" ;;
esac

echo "== 7. ⭐대조군 — 36 의 사유는 '없다'고 말하면 안 된다 =="
# 세 세션이 읽은 그 거짓 문장. 이 단언이 이 파일의 존재 이유다.
r=$(keychain_credential_reason 36 "$INTERACTION_ERR")
case "$r" in
  *"자격증명이 없다"*) bad "36 must not claim absence" "reason=$r — 재지 않은 원인을 단언한다" ;;
  *)                   ok  "36 does not claim absence" ;;
esac

echo "== 8. 44 의 사유는 부재를 말하고 고치는 명령을 담는다 =="
r=$(keychain_credential_reason 44 "$NOTFOUND_ERR")
case "$r" in
  *없다*) ok "44 names the absence" ;;
  *)      bad "44 names the absence" "reason=$r" ;;
esac
case "$r" in
  *add-generic-password*) ok "44 carries the fix command" ;;
  *)                      bad "44 carries the fix command" "reason=$r" ;;
esac

echo "== 9. 사유는 비밀을 절대 담지 않는다 =="
# 사유는 로그로 간다. 비밀이 인자로 들어오지 않는 설계인지 확인한다.
r=$(keychain_credential_reason 0 "")
case "$r" in
  *hunter2*) bad "reason leaks a secret" "reason=$r" ;;
  *)         ok  "reason takes rc+stderr only (비밀은 인자가 아니다)" ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
