#!/usr/bin/env bash
# 야간 라이브 E2E 자격증명을 Keychain 에 넣는다 — **형님이 직접 돌리는 유일한 단계.**
#
#   ⭐ GUI 의 Terminal.app 에서 돌려라 (Aqua 세션). Claude Code 셸이나 ssh 는
#      `Background` 세션이라 login keychain 의 잠금 연산이 막힌다.
#
#   bash ~/Works/_infra/scripts/setup-e2e-credential.sh
#
# 왜 스크립트인가 — 이 한 단계가 **네 세션 이월**됐고 처방이 **두 번 틀렸다**:
#   1회) "에이전트가 비대화형이라 macOS 가 거부한다"   → 거짓. 잠긴 login keychain 이었다
#   2회) "Keychain Access.app 에서 손으로 추가해달라"  → 잠금이 원인이면 그것도 막힌다
# 세 번째로 틀리지 않으려면 **넣은 뒤 읽어서 확인**하는 것까지가 이 스크립트의 일이다.
#
# ⚠️ 비밀번호는 이 스크립트도, 셸도, `ps` 도 보지 못한다. `security -w` 를 **인자
#    없이** 부르면 security 가 직접 두 번 묻고 값은 프로세스 밖으로 안 나간다.
#    (테스트: tests/test_e2e_credential_setup_guard.sh)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/keychain_credential.sh
. "$ROOT/scripts/lib/keychain_credential.sh"
declare -F keychain_credential_verdict >/dev/null || {
  echo "FATAL: lib/keychain_credential.sh 로드 실패"; exit 1; }

SERVICE="bsvibe-e2e-live"
ACCOUNT="${BSVIBE_E2E_EMAIL:-admin@bsvibe.dev}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

echo "== 1. 보안 세션 확인 =="
session=$(launchctl managername 2>/dev/null || echo "?")
echo "   launchctl managername = $session"
if [ "$session" != "Aqua" ]; then
  echo "   ⚠️  Aqua 가 아니다. login keychain 의 잠금 연산이 막힐 수 있다."
  echo "      GUI 의 Terminal.app 창에서 다시 돌려라. (계속은 하지만 실패하면 이게 원인이다)"
fi

echo "== 2. login keychain 이 잠겨 있는가 =="
if security show-keychain-info "$LOGIN_KC" >/dev/null 2>&1; then
  echo "   잠금 해제됨 — 그대로 진행한다"
else
  echo "   잠겨 있다. 잠금 해제한다 (macOS 로그인 비밀번호를 물어본다):"
  security unlock-keychain "$LOGIN_KC" || {
    echo "   ❌ 잠금 해제 실패 — 여기서 멈춘다. 넣어도 데몬이 못 읽는다."; exit 1; }
fi

echo "== 3. 자격증명 입력 ($SERVICE / $ACCOUNT) =="
echo "   security 가 직접 두 번 묻는다. 이 스크립트는 값을 보지 않는다."
echo "   넣을 값: $ACCOUNT 의 BSVibe 로그인 비밀번호"
security add-generic-password -U -s "$SERVICE" -a "$ACCOUNT" \
  -l "BSVibe live E2E (nightly runner)" -w || {
  echo "   ❌ 쓰기 실패 — 위 메시지가 원인이다."; exit 1; }

echo "== 4. 읽어서 확인한다 (값은 찍지 않는다) =="
# ⚠️ 넣었다는 것만으로 끝내지 않는다. 데몬이 하는 그 호출을 그대로 한다.
err=$(mktemp)
security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w >/dev/null 2>"$err"
rc=$?
verdict=$(keychain_credential_verdict "$rc" 1)
reason=$(keychain_credential_reason "$rc" "$(tr -d '\n' <"$err")")
rm -f "$err"

if [ "$verdict" = ok ]; then
  echo "   ✅ 데몬이 하는 그 호출로 읽힌다 (rc=0)."
  echo
  echo "다음 04:20 KST 실행부터 라이브 E2E 가 돈다."
  echo "확인: tail -30 $ROOT/logs/e2e-live-nightly.log"
  echo "지금 바로 돌려보려면 (형님 폰 알림은 끈 채):"
  echo "  BSVIBE_E2E_ALERT_ENV=/nonexistent bash $ROOT/scripts/e2e-live-nightly.sh"
  exit 0
fi

echo "   ❌ 넣었는데 읽히지 않는다 — $reason"
echo "      (verdict=$verdict) 이 줄을 그대로 다음 세션에 넘겨라. 추측하지 마라."
exit 1
