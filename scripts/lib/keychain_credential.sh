#!/usr/bin/env bash
# keychain_credential.sh — `security` 읽기 실패를 **원인별로** 나눈다.
#
# 왜 있나 — 야간 러너는 자격증명을 이렇게 읽었다:
#
#   password=$(security find-generic-password ... -w 2>/dev/null)
#   if [ -z "$password" ]; then echo "SKIP: Keychain 에 자격증명이 없다."
#
# `2>/dev/null` 이 이유를 버리고, **빈 문자열이 주장이 된다.** 두 세계가 접힌다:
#
#   rc=44  errSecItemNotFound          진짜 부재. 사람을 기다린다 → 알람 없이 SKIP.
#   rc=36  errSecInteractionNotAllowed **잠긴 keychain.** 항목이 있어도 못 읽는다.
#                                      사람을 기다리는 상태가 아니라 머신의 고장이다.
#
# 두 번째가 첫 번째의 문장을 입으면, 사람은 **이미 한 일을 다시 한다.** 실제로
# 이 프로젝트는 keychain 실패의 원인을 세 세션 동안 *"에이전트가 비대화형이라서"*
# 로 적었고 틀렸다 — 이 머신에서 재보니 별도 keychain 을 만들어 잠금 해제하면
# 같은 세션이 쓰기·읽기를 **전부 성공**한다. 막힌 것은 잠긴 `login.keychain-db`
# 하나뿐이었다.
#
# 판정을 여기 순수 함수로 두는 이유 — 러너 본체의 이 줄은 docker 스택과 70~90초
# E2E 를 통과해야만 닿는다. 거기 두면 영원히 테스트되지 않는다.
# 테스트: tests/test_keychain_credential_verdict.sh

# keychain_credential_verdict <rc> <has_secret:0|1>
#   ok         읽었다
#   absent     항목이 없다 — 사람을 기다린다 (알람 아님)
#   unreadable 읽을 수 없다 — 이 머신의 고장 (알람)
#
# ⚠️ 비밀 값은 인자로 받지 않는다. 사유는 로그로 나가고, `set -x` 도 인자를 찍는다.
#    호출자가 비어 있는지만 0/1 로 접어서 넘긴다.
keychain_credential_verdict() {
  local rc="${1:-1}" has_secret="${2:-0}"
  case "$rc" in
    0)  [ "$has_secret" = 1 ] && echo ok || echo unreadable ;;
    44) echo absent ;;
    # 36 = errSecInteractionNotAllowed. 그리고 **모르는 코드는 전부 여기로** —
    # 미래의 macOS 가 새 코드를 내면 기본값이 '조용한 SKIP' 이어선 안 된다.
    # 이 함수가 틀리려면 알람이 과하게 울리는 방향으로 틀려야 한다.
    *)  echo unreadable ;;
  esac
}

# keychain_credential_reason <rc> <stderr-text>
#   사람이 읽고 **바로 행동할 수 있는** 한 줄. rc=0 이면 빈 문자열(= 사유 없음).
keychain_credential_reason() {
  local rc="${1:-1}" err="${2:-}"
  case "$rc" in
    0)  : ;;
    44) printf '%s' "Keychain 에 자격증명이 없다 (rc=44 errSecItemNotFound). 넣기: security add-generic-password -s <service> -a <account> -w" ;;
    36) printf '%s' "Keychain 이 잠겨 있어 읽을 수 없다 (rc=36 errSecInteractionNotAllowed) — 항목이 있어도 못 읽는다. 잠금 해제: security unlock-keychain ~/Library/Keychains/login.keychain-db | stderr: ${err}" ;;
    *)  printf '%s' "Keychain 읽기가 알 수 없는 이유로 실패했다 (rc=${rc}) — 부재로 단정하지 마라 | stderr: ${err}" ;;
  esac
}
