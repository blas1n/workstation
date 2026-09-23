#!/usr/bin/env bash
# test_logrotate_derives_its_targets.sh — 로테이터가 목록을 **하드코딩하지 않는다.**
#
# 이 결함의 원본이 정확히 그 하드코딩이었다: `~/Library/Logs` 의
# `bsvibe-worker*.log` 하나. 그 범위 밖에서 autodeploy.log 가 225MB 로 자랐다.
# 다시 목록으로 되돌아가면 같은 자리에서 또 터진다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/bsvibe-worker-logrotate.sh"

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

echo "== 1. plist 에서 유도한다 =="
grep -q 'launchd_log_targets' "$S" && ok "calls launchd_log_targets" || bad "calls launchd_log_targets" "없음"
grep -q 'declare -F launchd_log_targets' "$S" && ok "pins that the lib loaded" || bad "pins that the lib loaded" "빈 집합이 조용히 통과한다"

echo "== 2. ⭐ 옛 하드코딩이 되돌아오지 않았다 (주석은 제외) =="
# ⚠️ 주석을 빼고 본다. 이 스크립트의 주석은 **옛 패턴을 일부러 인용**해 왜 바꿨는지를
#    적고 있다. 그걸 위반으로 세면 가드가 자기 설명에 걸려 빨개지고, 그러면 다음
#    사람이 가드를 느슨하게 만든다. (오늘 같은 함정에 세 번 걸렸다.)
code=$(grep -vE '^[[:space:]]*#' "$S")
case "$code" in
  *"name 'bsvibe-worker"*|*'name bsvibe-worker'*) bad "패턴 하드코딩이 돌아왔다" "find -name" ;;
  *) ok "no hardcoded filename pattern" ;;
esac
printf '%s\n' "$code" | grep -qE '^LOG_DIR=' && bad "단일 LOG_DIR 이 돌아왔다" "범위가 한 디렉터리로 좁아진다" || ok "no single LOG_DIR"
# 대조군 — 주석 제거가 파일을 통째로 삼키지 않았다
printf '%s\n' "$code" | grep -q 'launchd_log_targets' && ok "주석 제거 후에도 코드가 남아 있다" || bad "주석 제거 대조군" "코드가 비었다"

echo "== 3. ⭐ 대상 0개를 성공으로 보고하지 않는다 =="
# `rotated=0` 하나로는 "돌릴 게 없었다"와 "아무것도 안 봤다"가 구분되지 않는다.
# 다섯 달 동안 그렇게 숨었다.
grep -q 'targets=' "$S" && ok "reports the target count" || bad "reports the target count" "분모가 없다"
grep -qE 'targets.*-eq 0' "$S" && ok "fails when the set is empty" || bad "fails when the set is empty" "0개가 초록이 된다"

echo "== 4. 실제로 돌려 보면 대상이 잡힌다 (양성 대조군) =="
out=$(BSVIBE_LOGROTATE_MAX_BYTES=999999999999 bash "$S" 2>&1 | tail -1)
n=$(printf '%s' "$out" | sed -n 's/.*targets=\([0-9]*\).*/\1/p')
[ "${n:-0}" -gt 5 ] && ok "targets=${n} (>5)" || bad "targets" "out=$out"
case "$out" in *rotated=0*) ok "상한이 크면 아무것도 안 돌린다" ;; *) bad "대조군" "out=$out" ;; esac

echo "== 5. 문법 =="
bash -n "$S" 2>/dev/null && ok "bash -n clean" || bad "bash -n" "문법 오류"
bash -n "$ROOT/scripts/lib/logrotate_targets.sh" 2>/dev/null && ok "lib bash -n clean" || bad "lib" "문법 오류"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
