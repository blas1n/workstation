#!/usr/bin/env bash
# test_secrets_sync_wiring.sh — 본체가 판정 층을 **실제로 부르는지** 정적으로 고정한다.
# (test_nightly_classifies_the_credential_read.sh 와 같은 이유. 본체는 bw 네트워크
#  호출을 통과해야 닿아서 동적으로는 테스트가 못 간다.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/secrets-sync.sh"
M="$ROOT/secrets.manifest"

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

echo "== 1. 판정 층을 로드하고, 로드 실패를 스스로 잡는다 =="
grep -q 'secrets_manifest.sh' "$S" && ok "sources the lib" || bad "sources the lib" "없음"
grep -q 'declare -F leaf_verify' "$S" && ok "pins that it loaded" || bad "pins that it loaded" "빈 판정은 ok 가 아니다"

echo "== 2. 매니페스트를 검증하고 나서 움직인다 =="
mv=$(grep -n 'manifest_validate' "$S" | head -1 | cut -d: -f1)
bwg=$(grep -n 'bw get password' "$S" | head -1 | cut -d: -f1)
if [ -n "$mv" ] && [ -n "$bwg" ] && [ "$mv" -lt "$bwg" ]; then
  ok "validate before fetching"
else bad "validate before fetching" "validate=$mv fetch=$bwg"; fi

echo "== 3. ⭐ 쓴 뒤에 확인한다 (쓰기 성공 ≠ 제대로 쓰임) =="
grep -q 'leaf_verify "\$path"' "$S" && ok "verifies after write" || bad "verifies after write" "확인이 없다"

echo "== 4. ⭐ printf %s 로 쓴다 — echo 면 개행이 붙어 로그인이 실패한다 =="
case $(grep -c 'printf %s "\$secret"' "$S") in
  0) bad "writes with printf %s" "echo 를 쓰면 비번 끝에 \\n 이 붙는다" ;;
  *) ok "writes with printf %s" ;;
esac
grep -qE 'echo +"\$secret"' "$S" && bad "must not echo the secret" "개행 + 로그 유출" || ok "never echoes the secret"

echo "== 5. ⭐ 비밀을 출력하지 않는다 =="
# 실패 경로에서도 값이 새면 안 된다. 사유는 항목 이름과 경로까지다.
if grep -nE '(echo|printf).*\$secret' "$S" | grep -vq 'printf %s "\$secret" > "\$path"'; then
  bad "secret never reaches stdout" "$(grep -nE '(echo|printf).*\$secret' "$S" | head -1)"
else ok "secret never reaches stdout"; fi

echo "== 6. 마스터 비번을 디스크에 두지 않는다 =="
grep -qE 'passwordenv|passwordfile' "$S" && bad "master password stays off disk" "비대화형 unlock 은 비번을 디스크로 부른다" || ok "master password stays off disk"

echo "== 7. 매니페스트에 값이 없다 (git 에 올라간다) =="
if awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF>2 {found=1} END{exit !found}' "$M"; then
  bad "manifest carries no values" "세 번째 칸이 있다"
else ok "manifest carries no values"; fi

echo "== 8. 문법이 성립한다 =="
bash -n "$S" 2>/dev/null && ok "bash -n clean" || bad "bash -n clean" "문법 오류"
bash -n "$ROOT/scripts/lib/secrets_manifest.sh" 2>/dev/null && ok "lib bash -n clean" || bad "lib" "문법 오류"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
