#!/usr/bin/env bash
# test_secrets_sync_shows_candidates.sh — 못 찾았을 때 **후보를 보여준다.**
#
# 2026-09-23: 형님이 sync 를 돌렸더니 `FAIL bsvibe-e2e-live — 금고에서 못 읽었다`
# 가 떴다. 항목 이름이 다른 것이다. 그때 도구가 "이름이 맞나?" 로 끝내면 사람이
# 별도 명령을 찾아 쳐야 한다 — 도구는 **이미 세션을 들고 있으면서** 후보를 못
# 보여준 셈이다.
#
# 이 경로는 사람이 다음에 실제로 밟는 길이라, 스텁으로 끝까지 돌려 본다.
# (bw 를 진짜로 부르면 마스터 비번을 묻는다 — 테스트가 못 닿는 자리다.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# bw 스텁: status=unlocked, get 은 실패, list 는 후보 두 개를 낸다.
cat > "$tmp/bin/bw" <<'STUB'
#!/bin/bash
case "$1" in
  status) echo '{"status":"unlocked","userEmail":"x@y"}' ;;
  unlock) echo "STUB-SESSION" ;;
  sync)   : ;;
  get)    exit 1 ;;
  list)   echo '[{"name":"BSVibe E2E Live"},{"name":"bsvibe-admin"}]' ;;
  *)      : ;;
esac
STUB
chmod +x "$tmp/bin/bw"

printf 'bsvibe-e2e-live\t~/.bsvibe/_test_leaf\n' > "$tmp/m.tsv"
out=$(PATH="$tmp/bin:$PATH" BW_SESSION=STUB-SESSION SECRETS_MANIFEST="$tmp/m.tsv" \
        bash "$ROOT/scripts/secrets-sync.sh" 2>&1)
rc=$?

echo "== 1. 실패를 실패로 보고한다 =="
[ "$rc" != 0 ] && ok "exit code is non-zero" || bad "exit code" "rc=$rc"

echo "== 2. ⭐ 후보 이름을 보여준다 =="
case "$out" in *"BSVibe E2E Live"*) ok "후보를 출력한다" ;; *) bad "후보를 출력한다" "$(printf '%s' "$out" | tail -3)" ;; esac
case "$out" in *"bsvibe-admin"*)    ok "후보가 여러 개면 여러 개" ;; *) bad "여러 후보" "out=$out" ;; esac

echo "== 3. 무엇을 고치면 되는지 말한다 =="
case "$out" in *secrets.manifest*) ok "고칠 자리를 알려준다" ;; *) bad "고칠 자리" "out=$out" ;; esac

echo "== 4. ⭐ 음성 대조군 — 검색해도 후보가 없으면 그렇게 말한다 =="
cat > "$tmp/bin/bw" <<'STUB2'
#!/bin/bash
case "$1" in
  status) echo '{"status":"unlocked"}' ;;
  unlock) echo "STUB-SESSION" ;;
  get)    exit 1 ;;
  list)   echo '[]' ;;
  *)      : ;;
esac
STUB2
chmod +x "$tmp/bin/bw"
out2=$(PATH="$tmp/bin:$PATH" BW_SESSION=STUB-SESSION SECRETS_MANIFEST="$tmp/m.tsv" \
         bash "$ROOT/scripts/secrets-sync.sh" 2>&1)
case "$out2" in *"후보가 없다"*) ok "빈 결과를 빈 결과라 말한다" ;; *) bad "빈 결과" "out=$out2" ;; esac
case "$out2" in *"BSVibe"*) bad "후보가 없는데 후보를 지어낸다" "out=$out2" ;; *) ok "없으면 지어내지 않는다" ;; esac

echo "== 5. 비밀은 어느 경로에서도 안 찍힌다 =="
case "$out$out2" in *STUB-SESSION*) bad "세션 키가 출력됐다" "유출" ;; *) ok "세션 키가 출력되지 않는다" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
