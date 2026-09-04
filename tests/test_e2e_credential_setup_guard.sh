#!/usr/bin/env bash
# 자격증명 설치 헬퍼가 **비밀을 새게 하지 않고, 넣은 뒤 스스로 확인하는가.**
#
# 이 스크립트는 형님이 직접 돌리는 유일한 수동 단계다. 4세션 이월됐고 처방이
# **두 번 틀렸다**(GUI 로 손 추가 → 실은 잠금 / "에이전트 불가" → 실은 잠긴 keychain).
# 세 번째도 틀리면 안 되므로, 넣고 나서 **읽어서 확인**하는 것까지가 스크립트의 일이다.
#
# ⚠️ 비밀이 새는 경로는 셋이다 — 전부 막혔는지 어휘로 고정한다:
#   1. argv        (`-w "$pw"` → `ps` 에 보인다)
#   2. 에코/출력   (`echo "$pw"`)
#   3. 셸 이력     (변수에 담아 재사용)
# `security ... -w` 를 **인자 없이** 쓰면 security 가 직접 두 번 물어보고 프로세스
# 밖으로 나가지 않는다. 그게 유일하게 옳은 형태다.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/setup-e2e-credential.sh"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

[ -f "$S" ] || { echo "FAIL: $S 없음"; exit 1; }
[ -x "$S" ] || bad "실행 가능" "chmod +x 안 됨"

# ⚠️ 2026-09-04: 이 파일의 첫 판본은 **네 절단 중 셋을 놓쳤다.** 전부 같은 이유다 —
# 메커니즘이 아니라 **텍스트**를 물었다:
#   * `-w` 가 `\` 뒤 다음 줄에 있어 한 줄 grep 이 못 봤다
#   * `lib/keychain_credential.sh` 가 바로 위 `# shellcheck` **주석**에도 있었다
#   * `launchctl managername` 이 **`echo` 문자열**에도 있었다
# 그래서 여기서는 스크립트를 **코드 뷰**로 정규화해서 본다:
#   전체 줄 주석 제거 + `\` 줄 이음. 그리고 호출은 **호출 형태**로 못박는다.
code() {
  sed -e 's/^[[:space:]]*#.*$//' "$S" |
  awk '{ if (sub(/\\[[:space:]]*$/, "")) { printf "%s ", $0 } else { print } }'
}
CODE=$(code)

echo "== 1. 비밀이 argv 로 가지 않는다 =="
# `-w` 뒤에 값이 붙으면 `ps` 에 보인다. 줄 이음 뒤에 붙는 경우까지 잡는다.
hit=$(printf '%s\n' "$CODE" | grep -nE 'add-generic-password.*[[:space:]]-w[[:space:]]+[^|&;)[:space:]]' || true)
if [ -n "$hit" ]; then
  bad "no secret in argv" "$(printf '%s' "$hit" | head -1)"
else
  ok "no secret in argv (-w 가 인자 없이 쓰인다)"
fi

echo "== 2. 비밀을 변수에 담거나 출력하지 않는다 =="
if grep -nE 'read -s|echo "\$(pw|password|secret)' "$S" >/dev/null 2>&1; then
  bad "secret never enters the shell" "$(grep -nE 'read -s|echo "\$(pw|password|secret)' "$S" | head -1)"
else
  ok "secret never enters the shell (security 가 직접 묻는다)"
fi

echo "== 3. 넣은 뒤 읽어서 확인한다 — 그리고 값을 찍지 않는다 =="
grep -q 'find-generic-password' "$S" \
  && ok "verifies by reading back" \
  || bad "verifies by reading back" "넣었다는 것만으로 끝내면 처방이 세 번째로 틀려도 모른다"
if grep -nE 'find-generic-password[^|]*-w' "$S" | grep -vE '>/dev/null|>\s*/dev/null' >/dev/null; then
  bad "read-back must not print the secret" "$(grep -nE 'find-generic-password[^|]*-w' "$S" | head -1)"
else
  ok "read-back discards the value (rc 만 본다)"
fi

echo "== 4. 판정을 공유한다 — 러너와 같은 rc 해석을 쓴다 =="
# 여기서 rc 를 따로 해석하면 러너와 갈라지고, 갈라지면 덜 쓰이는 쪽이 썩는다.
# ⚠️ 파일명 문자열이 아니라 **dot-source 문**을 요구한다 — `# shellcheck source=` 주석이
#    똑같은 문자열을 갖고 있어서, 문자열만 보면 소싱을 지워도 초록이었다.
printf '%s\n' "$CODE" | grep -qE '^[[:space:]]*(\.|source)[[:space:]]+.*lib/keychain_credential\.sh' \
  && ok "sources the shared verdict lib" \
  || bad "sources the shared verdict lib" "rc 해석이 두 벌이 되면 갈라진다"
printf '%s\n' "$CODE" | grep -qE 'keychain_credential_reason[[:space:]]+"' \
  && ok "reports the measured reason on failure" \
  || bad "reports the measured reason on failure" "실패 원인을 또 추측하게 된다"
printf '%s\n' "$CODE" | grep -qE 'keychain_credential_verdict[[:space:]]+"' \
  && ok "uses the shared verdict" \
  || bad "uses the shared verdict" "판정 없이 rc 를 눈으로 읽으면 러너와 갈라진다"

echo "== 5. 세션을 확인한다 — Background 에서 돌면 헛수고다 =="
# ⚠️ **호출 형태**로 못박는다. `echo \"launchctl managername = ...\"` 라는 문자열이
#    같은 파일에 있어서, 문자열만 보면 호출을 지워도 초록이었다.
printf '%s\n' "$CODE" | grep -qE '\$\([[:space:]]*launchctl[[:space:]]+managername' \
  && ok "checks the security session (Aqua vs Background)" \
  || bad "checks the security session" "잠긴 세션에서 돌면 rc=36 을 받고 원인을 또 헤맨다"
printf '%s\n' "$CODE" | grep -q 'Aqua' \
  && ok "names the session it needs" \
  || bad "names the session it needs" "확인만 하고 무엇이어야 하는지 안 말하면 소용없다"

echo "== 6. 서비스·계정이 러너와 일치한다 — **대입문**으로 =="
printf '%s\n' "$CODE" | grep -qE '^[[:space:]]*SERVICE=.*bsvibe-e2e-live' \
  && ok "SERVICE=bsvibe-e2e-live" || bad "SERVICE=bsvibe-e2e-live" "러너가 찾는 키와 달라진다"
printf '%s\n' "$CODE" | grep -qE '^[[:space:]]*ACCOUNT=.*admin@bsvibe\.dev' \
  && ok "ACCOUNT=admin@bsvibe.dev" || bad "ACCOUNT=admin@bsvibe.dev" "러너의 기본 계정과 달라진다"

echo "== 7. 문법이 성립한다 =="
bash -n "$S" && ok "bash -n clean" || bad "bash -n clean" "구문 오류"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
