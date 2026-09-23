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

# ---------------------------------------------------------------------------
# 파일 소스 — launchd 가 login keychain 을 못 여는 문제의 우회 (2026-09-23)
# ---------------------------------------------------------------------------
# 형님이 위 rc=44 사유가 시킨 대로 자격증명을 넣으려다 막혔다:
#   $ security add-generic-password -s ... -w   →  User interaction not allowed (rc=36)
# 원인은 세션이다. SSH 셸의 `launchctl managername` 이 **Background** 라, 콘솔에
# 로그인돼 있어도 그 Aqua 세션이 아니라서 login keychain 에 못 닿는다.
#
# 넣는 데 성공해도 **야간 러너가 못 읽을 공산이 크다.** 같은 머신에서 이미 겪었고
# 코드에 적혀 있다 — `backend/executors/worker/claude_auth.py`: *"launchd 로 뜬
# CLI 는 보안 세션이 login keychain 을 못 연다"*. 워커는 그래서 키체인을 포기하고
# 파일/env 로 우회했다. 러너도 같은 벽이므로 같은 우회를 쓴다.
#
# ⇒ 파일을 **먼저** 본다. keychain 은 GUI 세션에서만 유효한 폴백으로 남긴다.
# 테스트: tests/test_credential_file_source.sh

# credential_file_verdict <path>
#   ok         0600(이하) 권한이고 내용이 있다
#   absent     파일이 없다 — keychain 으로 넘어가라
#   unreadable 있는데 못 쓴다 (비었거나, 남이 읽을 수 있다)
#
# ⚠️ 비밀 값을 echo 하지 않는다. 판정만 낸다.
credential_file_verdict() {
  local path="${1:-}"
  [ -n "$path" ] && [ -e "$path" ] || { echo absent; return; }
  [ -r "$path" ] || { echo unreadable; return; }
  # 비밀 파일이 그룹/타인에게 읽히면 **거부한다.** 키체인을 버리는 대가가 이것이고,
  # 조용히 받아들이면 평문 비밀이 누구나 읽는 자리에 남는다 — 오늘 launchd plist 의
  # 워커 토큰이 정확히 그 상태(-rw-r--r--)였다.
  # ⚠️ `stat` 을 이름으로 부르지 마라. **zsh 에는 `stat` 빌트인(zsh/stat)이 있어**
  # 같은 줄이 빈 문자열을 낸다 — 그러면 아래 case 가 안 맞아 0600 파일이
  # `unreadable` 로 판정된다. 러너는 bash 라 프로덕션은 멀쩡하지만, 사람이 zsh 에서
  # 이 함수를 불러 디버깅하면 **없는 권한 문제를 쫓게 된다.** 이 레포는 keychain
  # 실패의 원인을 세 세션 동안 엉뚱한 데서 찾은 전력이 있다. 경로로 부른다.
  local mode stat_bin=/usr/bin/stat
  mode=$("$stat_bin" -f '%OLp' "$path" 2>/dev/null || "$stat_bin" -c '%a' "$path" 2>/dev/null)
  case "$mode" in
    ?00|00|0) : ;;
    *) echo unreadable; return ;;
  esac
  [ -s "$path" ] && echo ok || echo unreadable
}

# credential_file_reason <path> — 사람이 바로 고칠 수 있는 한 줄. 비밀은 안 담는다.
credential_file_reason() {
  local path="${1:-}"
  local v mode
  v=$(credential_file_verdict "$path")
  [ "$v" = ok ] && return
  if [ ! -e "$path" ]; then
    printf '%s' "자격증명 파일이 없다: ${path}"
    return
  fi
  mode=$(stat -f '%OLp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null)
  if [ ! -s "$path" ]; then
    printf '%s' "자격증명 파일이 비어 있다: ${path} — 값을 넣어라"
  else
    printf '%s' "자격증명 파일을 남이 읽을 수 있다 (mode=${mode}): ${path} — 고치기: chmod 600 ${path}"
  fi
}

# credential_verdict <file-path> <keychain-rc> <keychain-has-secret:0|1>
#   두 소스를 **한 판정**으로 접는다. 파일이 이긴다 — launchd 에서 유일하게 되는 길이라서.
#
# ⚠️ 파일이 `unreadable` 이면 keychain 으로 넘어가지 **않는다.** 넘어가면 "있는데
#    권한이 틀린 파일"이 조용히 무시되고, 형님은 자기가 만든 파일이 왜 안 먹는지
#    영원히 모른다. 고장은 다음 소스로 덮는 게 아니라 말해야 한다.
credential_verdict() {
  local path="${1:-}" kc_rc="${2:-1}" kc_has="${3:-0}"
  local fv
  fv=$(credential_file_verdict "$path")
  case "$fv" in
    ok)         echo ok ;;
    unreadable) echo unreadable ;;
    *)          keychain_credential_verdict "$kc_rc" "$kc_has" ;;
  esac
}
