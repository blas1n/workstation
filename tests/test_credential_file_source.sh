#!/usr/bin/env bash
# test_credential_file_source.sh — launchd 는 login keychain 을 못 연다. 파일로 우회한다.
#
# 2026-09-23 실측. 형님이 러너가 시킨 대로 자격증명을 넣으려다 막혔다:
#
#   $ security add-generic-password -s bsvibe-e2e-live -a admin@bsvibe.dev -w
#   User interaction not allowed.        (rc=36 errSecInteractionNotAllowed)
#
# 원인은 세션이다 — SSH 셸의 `launchctl managername` 이 **Background** 다.
# 콘솔에 로그인돼 있어도 그 Aqua 세션이 아니라서 login keychain 에 못 닿는다.
#
# ⚠️ 그리고 넣는 데 성공해도 **야간 러너가 못 읽을 공산이 크다.** 같은 머신에서
# 이미 겪은 일이고 코드에 적혀 있다 — `backend/executors/worker/claude_auth.py`:
# *"launchd 로 뜬 CLI 는 보안 세션이 login keychain 을 못 연다"*. 워커는 그래서
# 키체인을 포기하고 env/파일로 우회했다. 러너도 같은 벽이다.
#
# ⇒ 파일을 **먼저** 본다. keychain 은 GUI 세션용 폴백으로 남긴다.
#
# 이 층이 순수 함수인 이유는 기존과 같다 — 러너 본체의 그 줄은 docker 스택과
# 70~90초 E2E 를 통과해야 닿아서, 거기 두면 영원히 테스트되지 않는다.
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/keychain_credential.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== 1. 0600 파일이 있으면 그것을 쓴다 =="
f="$tmp/ok.env"; printf 'secret\n' > "$f"; chmod 600 "$f"
v=$(credential_file_verdict "$f")
[ "$v" = ok ] && ok "0600 파일 = ok" || bad "0600 파일 = ok" "verdict=$v"

echo "== 2. 파일이 없으면 absent — keychain 으로 넘어가야 한다 =="
v=$(credential_file_verdict "$tmp/nope.env")
[ "$v" = absent ] && ok "없는 파일 = absent" || bad "없는 파일 = absent" "verdict=$v"

echo "== 3. 빈 파일은 ok 가 아니다 (있는데 비었다 = 고장) =="
f="$tmp/empty.env"; : > "$f"; chmod 600 "$f"
v=$(credential_file_verdict "$f")
[ "$v" = unreadable ] && ok "빈 파일 = unreadable" || bad "빈 파일 = unreadable" "verdict=$v"

echo "== 4. ⭐ 남이 읽을 수 있는 파일은 거부한다 =="
# 키체인을 버리고 파일로 가는 대가가 이것이다. 조용히 쓰면 비밀이 평문으로
# 누구나 읽는 자리에 남는다 — 오늘 plist 에서 워커 토큰이 정확히 그 상태였다.
f="$tmp/loose.env"; printf 'secret\n' > "$f"; chmod 644 "$f"
v=$(credential_file_verdict "$f")
[ "$v" = unreadable ] && ok "0644 파일 = unreadable (거부)" || bad "0644 파일 = unreadable" "verdict=$v"

echo "== 5. 그 거부는 이유를 말한다 (고칠 명령까지) =="
r=$(credential_file_reason "$f")
case "$r" in
  *chmod*600*) ok "사유가 고칠 명령을 담는다" ;;
  *)           bad "사유가 고칠 명령을 담는다" "reason=$r" ;;
esac

echo "== 6. 사유는 비밀을 담지 않는다 =="
f="$tmp/secretive.env"; printf 'hunter2\n' > "$f"; chmod 644 "$f"
r=$(credential_file_reason "$f")
case "$r" in
  *hunter2*) bad "사유가 비밀을 흘린다" "reason=$r" ;;
  *)         ok  "사유는 경로와 권한만 말한다" ;;
esac

echo "== 7. ⭐ 합산 판정: 파일이 이기고, 없으면 keychain 이 답한다 =="
# 이게 이 변경의 요점이다. 둘 중 하나만 보면 launchd 에서 영원히 SKIP 이다.
f="$tmp/win.env"; printf 'secret\n' > "$f"; chmod 600 "$f"
v=$(credential_verdict "$f" 36 0)     # keychain 은 잠겨 있다(rc=36)
[ "$v" = ok ] && ok "파일이 잠긴 keychain 을 이긴다" || bad "파일이 잠긴 keychain 을 이긴다" "verdict=$v"

v=$(credential_verdict "$tmp/nope.env" 0 1)   # 파일 없음 + keychain 성공
[ "$v" = ok ] && ok "파일이 없으면 keychain 이 답한다" || bad "파일이 없으면 keychain" "verdict=$v"

v=$(credential_verdict "$tmp/nope.env" 44 0)  # 둘 다 없음
[ "$v" = absent ] && ok "둘 다 없으면 absent (사람 대기)" || bad "둘 다 없으면 absent" "verdict=$v"

v=$(credential_verdict "$tmp/nope.env" 36 0)  # 파일 없음 + keychain 잠김
[ "$v" = unreadable ] && ok "파일 없고 keychain 잠김 = unreadable (알람)" || bad "unreadable" "verdict=$v"

echo "== 8. 음성 대조군 — 전부 ok 를 뱉는 구현은 통과 못 한다 =="
v=$(credential_verdict "$tmp/loose.env" 44 0) # 느슨한 파일 + keychain 부재
[ "$v" = unreadable ] && ok "느슨한 파일은 absent 로 접히지 않는다" || bad "느슨한 파일" "verdict=$v"

echo "== 9. ⭐ zsh 에서도 같은 답을 낸다 (stat 빌트인 함정) =="
# 2026-09-23: 이 함수를 zsh 에서 불렀더니 0600 파일을 `unreadable` 이라 했다.
# zsh 의 `stat` 빌트인(zsh/stat)이 `-f '%OLp'` 를 모르고 빈 문자열을 내기 때문이다.
# 러너는 bash 라 프로덕션은 멀쩡했지만, **사람이 디버깅하는 셸은 zsh 다.**
if command -v zsh >/dev/null 2>&1; then
  f="$tmp/zsh.env"; printf 'secret\n' > "$f"; chmod 600 "$f"
  v=$(zsh -c ". scripts/lib/keychain_credential.sh; credential_file_verdict '$f'" 2>/dev/null | tail -1)
  [ "$v" = ok ] && ok "zsh 에서도 0600 = ok" || bad "zsh 에서도 0600 = ok" "verdict=$v"
  # 대조군 — zsh 에서도 느슨한 파일은 거부해야 한다
  chmod 644 "$f"
  v=$(zsh -c ". scripts/lib/keychain_credential.sh; credential_file_verdict '$f'" 2>/dev/null | tail -1)
  [ "$v" = unreadable ] && ok "zsh 에서도 0644 = unreadable" || bad "zsh 0644" "verdict=$v"
else
  echo "  skip — zsh 없음"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
